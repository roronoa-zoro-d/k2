/**
 * Copyright      2020  Xiaomi Corporation (authors: Daniel Povey,
 *                                                   Wei Kang)
 *
 * See LICENSE for clarification regarding multiple authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <algorithm>
#include <limits>
#include <vector>

#include "k2/csrc/array_ops.h"
#include "k2/csrc/device_guard.h"
#include "k2/csrc/fsa_algo.h"
#include "k2/csrc/fsa_utils.h"
#include "k2/csrc/hash.h"
#include "k2/csrc/intersect_dense_pruned.h"
#include "k2/csrc/ragged_ops.h"
#include "k2/csrc/thread_pool.h"

namespace k2 {
using namespace intersect_pruned_internal;  // NOLINT

/*
   Pruned intersection (a.k.a. composition) that corresponds to decoding for
   speech recognition-type tasks.  Can use either different decoding graphs (one
   per acoustic sequence) or a shared graph
*/
class MultiGraphDenseIntersectPruned {
 public:
  /**
     Pruned intersection (a.k.a. composition) that corresponds to decoding for
     speech recognition-type tasks

       @param [in] a_fsas  The decoding graphs, one per sequence.  E.g. might
                           just be a linear sequence of phones, or might be
                           something more complicated.  Must have either the
                           same Dim0() as b_fsas, or Dim0()==1 in which
                           case the graph is shared.
       @param [in] num_seqs  The number of sequences to do intersection at a
                             time, i.e. batch size. The input DenseFsaVec in
                             `Intersect` function MUST have `Dim0()` equals to
                             this.
       @param [in] search_beam  "Default" search/decoding beam.  The actual
                           beam is dynamic and also depends on max_active and
                           min_active.
       @param [in] output_beam  Beam for pruning the output FSA, will
                                typically be smaller than search_beam.
       @param [in] min_active  Minimum number of FSA states that are allowed to
                           be active on any given frame for any given
                           intersection/composition task. This is advisory,
                           in that it will try not to have fewer than this
                           number active.
       @param [in] max_active  Maximum number of FSA states that are allowed to
                           be active on any given frame for any given
                           intersection/composition task. This is advisory,
                           in that it will try not to exceed that but may not
                           always succeed.  This determines the hash size.
       @param [in] allow_partial If true and there was no final state active,
                           we will treat all the states on the last frame
                           to be final state. If false, we only
                           care about the real final state in the decoding
                           graph on the last frame when generating lattice.

       @param [in] online_decoding  True for online decoding (i.e. chunk by
                                    chunk decoding), false for running in batch
                                    mode.
   */
  MultiGraphDenseIntersectPruned(FsaVec &a_fsas, int32_t num_seqs,
                                 float search_beam, float output_beam,
                                 int32_t min_active, int32_t max_active,
                                 bool allow_partial,
                                 bool online_decoding)
      : a_fsas_(a_fsas),
        num_seqs_(num_seqs),
        search_beam_(search_beam),
        output_beam_(output_beam),
        min_active_(min_active),
        max_active_(max_active),
        allow_partial_(allow_partial),
        online_decoding_(online_decoding),
        dynamic_beams_(a_fsas.Context(), num_seqs, search_beam),
        forward_semaphore_(1),
        final_t_(a_fsas.Context(), num_seqs, 0) {
    NVTX_RANGE(K2_FUNC);
    T_ = 0;
    c_ = GetContext(a_fsas.shape);
    K2_CHECK_GT(search_beam, 0);
    K2_CHECK_GT(output_beam, 0);
    K2_CHECK_GE(min_active, 0);
    K2_CHECK_GT(max_active, min_active);
    K2_CHECK(a_fsas.shape.Dim0() == num_seqs || a_fsas.shape.Dim0() == 1);
    K2_CHECK_GE(num_seqs, 1);

    int32_t num_buckets = RoundUpToNearestPowerOfTwo(num_seqs * 4 *
                                                     max_active);
    if (num_buckets < 128)
      num_buckets = 128;
    int32_t num_a_copies;
    if (a_fsas.shape.Dim0() == 1) {
      a_fsas_stride_ = 0;
      state_map_fsa_stride_ = a_fsas.TotSize(1);
      num_a_copies = num_seqs;
    } else {
      K2_CHECK_EQ(a_fsas.shape.Dim0(), num_seqs);
      a_fsas_stride_ = 1;
      state_map_fsa_stride_ = 0;
      num_a_copies = 1;
    }
    // +1, because all-ones is not a valid key.
    int64_t num_keys = num_a_copies * (int64_t)a_fsas.TotSize(1) + 1;

    // To reduce the number of template instantiations, we limit the
    // code to use either 32 or 36 or 40 bits.
    // 32 can be optimized in future so if the num_keys is less than
    // 1<<32, we favor that value.
    int32_t num_key_bits;
    if ((num_keys >> 32) == 0)
      num_key_bits = 32;
    else if ((num_keys >> 36) == 0)
      num_key_bits = 36;
    else {
      num_key_bits = 40;
      if ((num_keys >> 40) != 0) {
        K2_LOG(FATAL) << "Too many keys for hash, please extend this code "
            "with more options: num_keys=" << num_keys;
      }
    }
    state_map_ = Hash(c_, num_buckets, num_key_bits);
  }

  /* Does the main work of intersection/composition, but doesn't produce any
     output; the output is provided when you call FormatOutput().

       @param [in] b_fsas  The neural-net output, with each frame containing the
                           log-likes of each phone.  A series of sequences of
                           (in general) different length.
   */
  void Intersect(DenseFsaVec *b_fsas) {
    /*
      T is the largest number of (frames+1) of neural net output, or the largest
      number of frames of log-likelihoods we count the final frame with (0,
      -inf, -inf..) that is used for the final-arc.  The largest number of
      states in the fsas represented by b_fsas equals T+1 (e.g. 1 frame would
      require 2 states, because that 1 frame is the arc from state 0 to state
      1).  So the #states is 2 greater than the actual number of frames in the
      neural-net output.
    */

    K2_CHECK(!online_decoding_);
    K2_CHECK(c_->IsCompatible(*b_fsas->Context()));

    b_fsas_ = b_fsas;
    K2_CHECK_EQ(num_seqs_, b_fsas_->shape.Dim0());
    T_ = T_ + b_fsas_->shape.MaxSize(1);

    { // set up do_pruning_after_ and prune_t_begin_end_.

      do_pruning_after_.resize(T_ + 1, (char)0);

      // each time we prune, prune 30 frames; but shift by 20 frames each
      // time so there are 10 frames of overlap.
      int32_t prune_num_frames = 30,
                   prune_shift = 20,
                             T = T_;
      K2_CHECK_GT(prune_num_frames, prune_shift);
      // The first begin_t is negative but will be rounded up to zero to get the
      // start of the range.  The motivation is: we don't want to wait until we
      // have processed `prune_num_frames` frames to prune for the first time,
      // because that first interval of not-pruning, being larger than normal,
      // would dominate the maximum memory used by intersection.
      for (int32_t begin_t = prune_shift - prune_num_frames; ;
           begin_t += prune_shift) {
        int32_t prune_begin = std::max<int32_t>(0, begin_t),
                  prune_end = begin_t + prune_num_frames;
        bool last = false;
        if (prune_end >= T) {
          prune_end = T;
          last = true;
        }
        K2_CHECK_LT(prune_begin, prune_end);
        do_pruning_after_[prune_end - 1] = (char)1;
        prune_t_begin_end_.push_back({prune_begin, prune_end});
        if (last)
          break;
      }
    }

    int32_t T = T_;

    std::ostringstream os;
    os << "Intersect:T=" << T << ",num_fsas=" << num_seqs_
       << ",TotSize(1)=" << b_fsas_->shape.TotSize(1);
    NVTX_RANGE(os.str().c_str());

    ThreadPool* pool = GetThreadPool();
    pool->SubmitTask([this]() { BackwardPassStatic(this); });

    // we'll initially populate frames_[0.. T+1], but discard the one at T+1,
    // which has no arcs or states, the ones we use are from 0 to T.
    frames_.reserve(T + 2);

    frames_.push_back(InitialFrameInfo());

    for (int32_t t = 0; t <= T; t++) {
      if (state_map_.NumKeyBits() == 32) {
        frames_.push_back(PropagateForward<32>(t, frames_.back().get()));
      } else if (state_map_.NumKeyBits() == 36) {
        frames_.push_back(PropagateForward<36>(t, frames_.back().get()));
      } else {
        K2_CHECK_EQ(state_map_.NumKeyBits(), 40);
        frames_.push_back(PropagateForward<40>(t, frames_.back().get()));
      }
      if (do_pruning_after_[t]) {
        // let a phase of backward-pass pruning commence.
        backward_semaphore_.Signal(c_);
        // note: normally we should acquire forward_semaphore_ without having to
        // wait.  It avoids the backward pass getting too far behind the forward
        // pass, which could mean too much memory is used.
        forward_semaphore_.acquire();
      }
    }
    // The FrameInfo for time T+1 will have no states.  We did that
    // last PropagateForward so that the 'arcs' member of frames_[T]
    // is set up (it has no arcs but we need the shape).
    frames_.pop_back();

    pool->WaitAllTasksFinished();
  }

  /* Does the main work of intersection/composition, but doesn't produce any
     output; the output is provided when you call FormatOutput().
     Does almost the same work as `Intersect`, except that this would be call
     serveral times for chunk by chunk decoding.

       @param [in] b_fsas  The neural-net output, with each frame containing the
                           log-likes of each phone.  A series of sequences of
                           (in general) different length.
       @param [in] frames  The frames generated for previously decoded chunks.
       @param [in] beams  Current search beams for each of the sequences, it has
                     `beams.Dim() == num_seqs_`.
       @return  A pointer to current `frames_`, which would be useful to
                generate `DecodeStateInfo` for each sequences.
  */
  const std::vector<std::unique_ptr<FrameInfo>>* OnlineIntersect(
      DenseFsaVec *b_fsas,
      std::vector<std::unique_ptr<FrameInfo>> &frames,
      Array1<float> &beams) {
    K2_CHECK(online_decoding_);
    K2_CHECK(c_->IsCompatible(*b_fsas->Context()));
    K2_CHECK_EQ(a_fsas_.shape.Dim0(), 1);
    K2_CHECK_EQ(num_seqs_, b_fsas->shape.Dim0());

    // update data members
    b_fsas_ = b_fsas;
    frames_.swap(frames);
    dynamic_beams_ = beams.To(c_);

    // T_ is the actual number of frames we have already processed in previous
    // chunks, -1 here because frames_ includes the initial frame.
    T_ = frames_.size() - 1;
    // -1 here because we add extra frame to b_fsas_ (to handle -1 arc)
    // see dense_fsa_vec.py for more details of converting nnet_outputs to fsas.
    int32_t chunk_size = b_fsas_->shape.MaxSize(1) - 1;
    int32_t T = T_ + chunk_size;

    // plus initial frame, we actually have T + 1 frames.
    frames_.reserve(T + 1);

    // we only do PropagateForward for real frames(i.e. not including the extra
    // frame we added to b_fsas_.
    for (int32_t t = 0; t < chunk_size; t++) {
      if (state_map_.NumKeyBits() == 32) {
        frames_.push_back(PropagateForward<32>(t, frames_.back().get()));
      } else if (state_map_.NumKeyBits() == 36) {
        frames_.push_back(PropagateForward<36>(t, frames_.back().get()));
      } else {
        K2_CHECK_EQ(state_map_.NumKeyBits(), 40);
        frames_.push_back(PropagateForward<40>(t, frames_.back().get()));
      }
      if (t == chunk_size - 1) {
        int32_t start = std::max<int32_t>(0, T_ - 2);
        PruneTimeRange(start, T_ + t + 1);
      }
    }
    int32_t history_t = T_;
    const int32_t *b_fsas_row_splits1 = b_fsas_->shape.RowSplits(1).Data();
    int32_t *final_t_data = final_t_.Data();

    // Get final frame of each sequences.
    K2_EVAL(
        c_, num_seqs_, lambda_set_final_and_final_t, (int32_t i)->void {
          int32_t b_chunk_size =
              b_fsas_row_splits1[i + 1] - b_fsas_row_splits1[i];
          final_t_data[i] = history_t + b_chunk_size;
        });

    // T_ will be used in FormatOutput, plus 1 here because we need an extra
    // frame for final arcs (i.e. the partial_final_frame return by
    // GetFinalFrame()) to construct the lattice.
    T_ = T + 1;
    return &frames_;
  }

  /* Propagate the last frame in b_fsas_(i.e. the extra frame containing only 0
     and -infs). See dense_fsa_vec.py to get more details of b_fsas_.

     The purpose of this function is to get the final states to construct
     partial results for online decoding. It suppose to be invoked in
     FormatOutput when online_decoding_ is True.

     This function returns the final FrameInfo needed by the FormatOutput. The
     final_frame->states contains the final state for each sequence (if it has),
     the final_frame->arcs actually contains no arc at all, but we need its
     shape.

     This function also adds the arcs to frames_.back(), normally the arcs of
     frames_.back() will be populated in next ForwardPass, we populate it here
     so that we can get valid fsas in FormatOutput. It will not affect the
     ForwardPass because the ForwardPass only need the states in frames_.back().
     Actually we will re-expand the arcs in frames_.back() in the next
     ForwardPass.
   */
  std::unique_ptr<FrameInfo> GetFinalFrame() {
    K2_CHECK(online_decoding_);

    // chunk_size is the index of the added extra frame.
    int32_t chunk_size = b_fsas_->shape.MaxSize(1) - 1;
    FrameInfo *cur_frame = frames_.back().get();

    // These are all of the expanded arcs, actually we only need the arcs
    // pointing to the final states.
    auto arcs = GetArcs(chunk_size, cur_frame);

    int32_t num_fsas = NumFsas();

    // Number of final states for each sequence, should be 0 or 1.
    Array1<int32_t> num_final_states(c_, num_fsas + 1, 0);
    // Keep the arcs pointing to final states.
    Renumbering renumber_arcs(c_, arcs.NumElements());
    char *keep_this_arc_data = renumber_arcs.Keep().Data();
    const int32_t *arcs_row_ids1_data = arcs.RowIds(1).Data(),
                  *arcs_row_ids2_data = arcs.RowIds(2).Data(),
                  *fsa_row_split1_data = a_fsas_.RowSplits(1).Data();
    int32_t *num_final_states_data = num_final_states.Data();
    ArcInfo *arcs_data = arcs.values.Data();

    K2_EVAL(
        c_, arcs.NumElements(), lambda_renumber_arc, (int32_t idx012) -> void {
        int32_t idx01 = arcs_row_ids2_data[idx012],
                idx0 = arcs_row_ids1_data[idx01];
        ArcInfo ai = arcs_data[idx012];
        // Arcs pointing to final states have non infinity scores
        if (ai.arc_loglike - ai.arc_loglike == 0) {
          num_final_states_data[idx0] = 1;
          keep_this_arc_data[idx012] = 1;
        } else {
          keep_this_arc_data[idx012] = 0;
        }
      });

    int32_t num_arcs = renumber_arcs.NumNewElems();
    const int32_t *new2old_data = renumber_arcs.New2Old().Data();
    Array1<ArcInfo> new_arcs(c_, num_arcs);
    ArcInfo *new_arcs_data = new_arcs.Data();

    K2_EVAL(c_, num_arcs, lambda_set_new_arcs, (int32_t new_idx012) -> void {
        int32_t old_idx012 = new2old_data[new_idx012];
        ArcInfo old_ai = arcs_data[old_idx012];
        // Only 1 state (the final state) in next frame, so idx1 is always 0.
        old_ai.u.dest_info_state_idx1 = 0;
        new_arcs_data[new_idx012] = old_ai;
    });

    auto old2new_rowsplits = renumber_arcs.Old2New(true);
    auto old2new_shape = RaggedShape2(&old2new_rowsplits, nullptr, num_arcs);
    auto total_shape = ComposeRaggedShapes(arcs.shape, old2new_shape);
    auto new_arcs_shape = RemoveAxis(total_shape, 2);
    cur_frame->arcs = Ragged<ArcInfo>(new_arcs_shape, new_arcs);

    std::unique_ptr<FrameInfo> ans = std::make_unique<FrameInfo>();
    ExclusiveSum(num_final_states, &num_final_states);
    auto final_state_shape = RaggedShape2(
        &num_final_states, nullptr, -1);
    // No arcs for final frame, but we need its shape in FormatOutput.
    auto state_to_arc_shape = RegularRaggedShape(
        c_, final_state_shape.NumElements(), 0);
    auto final_arc_shape = ComposeRaggedShapes(
        final_state_shape, state_to_arc_shape);
    ans->arcs = Ragged<ArcInfo>(final_arc_shape, Array1<ArcInfo>(c_, 0));
    return ans;
  }


  void BackwardPass() {
    int32_t num_fsas = b_fsas_->shape.Dim0(),
      num_work_items = max_active_ * num_fsas * T_;
    ParallelRunner pr(c_);
    // if num_work_items is big enough, it will actually create a new stream.
    cudaStream_t stream = pr.NewStream(num_work_items);
    With w(stream);  // This overrides whatever stream c_ contains with `stream`, if it's not


    NVTX_RANGE(K2_FUNC);
    for (size_t i = 0; i < prune_t_begin_end_.size(); i++) {
      backward_semaphore_.Wait(c_);
      int32_t prune_t_begin = prune_t_begin_end_[i].first,
                prune_t_end = prune_t_begin_end_[i].second;
      PruneTimeRange(prune_t_begin, prune_t_end);
      forward_semaphore_.release();
    }
  }

  static void BackwardPassStatic(MultiGraphDenseIntersectPruned *c) {
    // WARNING(fangjun): this is run in a separate thread, so we have
    // to reset its default device. Otherwise, it will throw later
    // if the main thread is using a different device.
    DeviceGuard guard(c->c_);
    c->BackwardPass();
  }

  // Return FrameInfo for 1st frame, with `states` set but `arcs` not set.
  std::unique_ptr<FrameInfo> InitialFrameInfo() {
    NVTX_RANGE("InitialFrameInfo");
    int32_t num_fsas = b_fsas_->shape.Dim0();
    std::unique_ptr<FrameInfo> ans = std::make_unique<FrameInfo>();

    if (a_fsas_.Dim0() == 1) {
      int32_t start_states_per_seq = (a_fsas_.shape.TotSize(1) > 0),  // 0 or 1
          num_start_states = num_fsas * start_states_per_seq;
      ans->states = Ragged<StateInfo>(
          RegularRaggedShape(c_, num_fsas, start_states_per_seq),
          Array1<StateInfo>(c_, num_start_states));
      StateInfo *states_data = ans->states.values.Data();
      K2_EVAL(
          c_, num_start_states, lambda_set_states, (int32_t i)->void {
            StateInfo info;
            info.a_fsas_state_idx01 = 0;  // start state of a_fsas_
            info.forward_loglike = FloatToOrderedInt(0.0);
            states_data[i] = info;
          });
    } else {
      Ragged<int32_t> start_states = GetStartStates(a_fsas_);
      ans->states =
          Ragged<StateInfo>(start_states.shape,
                            Array1<StateInfo>(c_, start_states.NumElements()));
      StateInfo *ans_states_values_data = ans->states.values.Data();
      const int32_t *start_states_values_data = start_states.values.Data();

      K2_EVAL(
          c_, start_states.NumElements(), lambda_set_state_info,
          (int32_t states_idx01)->void {
            StateInfo info;
            info.a_fsas_state_idx01 = start_states_values_data[states_idx01];
            info.forward_loglike = FloatToOrderedInt(0.0);
            ans_states_values_data[states_idx01] = info;
          });
    }
    return ans;
  }

  void FormatOutput(FsaVec *ofsa, Array1<int32_t> *arc_map_a,
                    Array1<int32_t> *arc_map_b) {
    NVTX_RANGE("FormatOutput");

    bool online_decoding = online_decoding_;
    bool allow_partial = allow_partial_;
    std::unique_ptr<FrameInfo> partial_final_frame;
    if (online_decoding) {
      partial_final_frame = std::move(GetFinalFrame());
      K2_CHECK(arc_map_a);
      K2_CHECK_EQ(arc_map_b, nullptr);
    } else {
      K2_CHECK(arc_map_a && arc_map_b);
    }

    int32_t T = T_;
    ContextPtr c_cpu = GetCpuContext();
    Array1<ArcInfo *> arcs_data_ptrs(c_cpu, T + 1);
    Array1<int32_t *> arcs_row_splits1_ptrs(c_cpu, T + 1);
    for (int32_t t = 0; t < T; t++) {
      arcs_data_ptrs.Data()[t] = frames_[t]->arcs.values.Data();
      arcs_row_splits1_ptrs.Data()[t] = frames_[t]->arcs.RowSplits(1).Data();
    }
    arcs_data_ptrs.Data()[T] = online_decoding
                                   ? partial_final_frame->arcs.values.Data()
                                   : frames_[T]->arcs.values.Data();
    arcs_row_splits1_ptrs.Data()[T] =
        online_decoding ? partial_final_frame->arcs.RowSplits(1).Data()
                        : frames_[T]->arcs.RowSplits(1).Data();

    // transfer to GPU if we're using a GPU
    arcs_data_ptrs = arcs_data_ptrs.To(c_);
    ArcInfo **arcs_data_ptrs_data = arcs_data_ptrs.Data();
    arcs_row_splits1_ptrs = arcs_row_splits1_ptrs.To(c_);
    int32_t **arcs_row_splits1_ptrs_data = arcs_row_splits1_ptrs.Data();
    const int32_t *b_fsas_row_splits1 = b_fsas_->shape.RowSplits(1).Data();
    const int32_t *a_fsas_row_splits1 = a_fsas_.RowSplits(1).Data();
    int32_t a_fsas_stride = a_fsas_stride_;  // 0 or 1 depending if the decoding
                                             // graph is shared.
    int32_t *final_t_data = final_t_.Data();
    int32_t num_fsas = b_fsas_->shape.Dim0();

    RaggedShape final_arcs_shape;
    { /*  This block populates `final_arcs_shape`.  It is the shape of a ragged
          tensor of arcs that conceptually would live at frames_[T+1]->arcs.  It
          contains no actual arcs, but may contain some states, that represent
          "missing" final-states.  The problem we are trying to solve is that
          there was a start-state for an FSA but no final-state because it did
          not survive pruning, and this could lead to an output FSA that is
          invalid or is misinterpreted (because we are interpreting a non-final
          state as a final state).
       */
      Array1<int32_t> num_extra_states(c_, num_fsas + 1);
      int32_t *num_extra_states_data = num_extra_states.Data();
      K2_EVAL(c_, num_fsas, lambda_set_num_extra_states, (int32_t i) -> void {
          int32_t final_t = online_decoding ? final_t_data[i]
                          : b_fsas_row_splits1[i+1] - b_fsas_row_splits1[i];

          int32_t *arcs_row_splits1_data = arcs_row_splits1_ptrs_data[final_t];
          int32_t num_states_final_t = arcs_row_splits1_data[i + 1] -
                                       arcs_row_splits1_data[i];
          K2_CHECK_LE(num_states_final_t, 1);

          // has_start_state is 1 if there is a start-state; note, we don't prune
          // the start-states, so they'll be present if they were present in a_fsas_.
          int32_t has_start_state = (a_fsas_row_splits1[i * a_fsas_stride] <
                                     a_fsas_row_splits1[i * a_fsas_stride + 1]);

          // num_extra_states_data[i] will be 1 if there was a start state but no final-state;
          // else, 0.
          num_extra_states_data[i] = has_start_state * (1 - num_states_final_t);
        });
      ExclusiveSum(num_extra_states, &num_extra_states);

      RaggedShape top_shape = RaggedShape2(&num_extra_states, nullptr, -1),
               bottom_shape = RegularRaggedShape(c_, top_shape.NumElements(), 0);
      final_arcs_shape = ComposeRaggedShapes(top_shape, bottom_shape);
    }


    RaggedShape oshape;
    // see documentation of Stack() in ragged_ops.h for explanation.
    Array1<uint32_t> oshape_merge_map;

    {
      NVTX_RANGE("InitOshape");
      // each of these have 3 axes.
      std::vector<RaggedShape *> arcs_shapes(T + 2);
      for (int32_t t = 0; t < T; t++)
        arcs_shapes[t] = &(frames_[t]->arcs.shape);

      arcs_shapes[T] = online_decoding ? &(partial_final_frame->arcs.shape)
                                       : &(frames_[T]->arcs.shape);

      arcs_shapes[T + 1] = &final_arcs_shape;

      // oshape is a 4-axis ragged tensor which is indexed:
      //   oshape[fsa_index][t][state_idx][arc_idx]
      int32_t axis = 1;
      oshape = Stack(axis, T + 2, arcs_shapes.data(), &oshape_merge_map);
    }

    int32_t *oshape_row_ids3 = oshape.RowIds(3).Data(),
            *oshape_row_ids2 = oshape.RowIds(2).Data(),
            *oshape_row_ids1 = oshape.RowIds(1).Data(),
            *oshape_row_splits3 = oshape.RowSplits(3).Data(),
            *oshape_row_splits2 = oshape.RowSplits(2).Data(),
            *oshape_row_splits1 = oshape.RowSplits(1).Data();

    int32_t num_arcs = oshape.NumElements();
    *arc_map_a = Array1<int32_t>(c_, num_arcs);
    if (!online_decoding)
      *arc_map_b = Array1<int32_t>(c_, num_arcs);
    int32_t *arc_map_a_data = arc_map_a->Data(),
            *arc_map_b_data = online_decoding ? nullptr : arc_map_b->Data();
    Array1<Arc> arcs_out(c_, num_arcs);
    Arc *arcs_out_data = arcs_out.Data();
    const Arc *a_fsas_arcs = a_fsas_.values.Data();
    int32_t b_fsas_num_cols = b_fsas_->scores.Dim1();
    const int32_t *b_fsas_row_ids1 = b_fsas_->shape.RowIds(1).Data();

    const uint32_t *oshape_merge_map_data = oshape_merge_map.Data();

    K2_EVAL(
        c_, num_arcs, lambda_format_arc_data,
        (int32_t oarc_idx0123)->void {  // by 'oarc' we mean arc with shape `oshape`.
          int32_t oarc_idx012 = oshape_row_ids3[oarc_idx0123],
                   oarc_idx01 = oshape_row_ids2[oarc_idx012],
                    oarc_idx0 = oshape_row_ids1[oarc_idx01],
                   oarc_idx0x = oshape_row_splits1[oarc_idx0],
                  oarc_idx0xx = oshape_row_splits2[oarc_idx0x],
                    oarc_idx1 = oarc_idx01 - oarc_idx0x,
             oarc_idx01x_next = oshape_row_splits2[oarc_idx01 + 1];

        uint32_t m = oshape_merge_map_data[oarc_idx0123];
        int32_t  t = m % uint32_t(T + 2),  // actually we won't get t == T or t == T + 1
                                            // here since those frames have no arcs.
                arcs_idx012 = m / uint32_t(T + 2);  // arc_idx012 into FrameInfo::arcs on time t,
                                            // index of the arc on that frame.

          K2_CHECK_EQ(t, oarc_idx1);

          const ArcInfo *arcs_data = arcs_data_ptrs_data[t];

          ArcInfo arc_info = arcs_data[arcs_idx012];
          Arc arc;
          arc.src_state = oarc_idx012 - oarc_idx0xx;
          // Note: the idx1 w.r.t. the frame's `arcs` is an idx2 w.r.t. `oshape`.
          int32_t dest_state_idx012 = oarc_idx01x_next +
                                      arc_info.u.dest_info_state_idx1;
          arc.dest_state = dest_state_idx012 - oarc_idx0xx;
          int32_t arc_label = a_fsas_arcs[arc_info.a_fsas_arc_idx012].label;
          arc.label = arc_label;

          int32_t final_t = online_decoding ? final_t_data[oarc_idx0]
              :b_fsas_row_splits1[oarc_idx0+1] - b_fsas_row_splits1[oarc_idx0];
          if (t == final_t - 1 && arc_label != -1) {
            if (allow_partial) {
              arc.label = -1;
              arc_info.a_fsas_arc_idx012 = -1;
            } else {
              // Unreachable code.
              K2_LOG(FATAL) <<
                "arc.labe != -1 on final_arc when allow_partial==false.";
            }
          }

          arc.score = arc_info.arc_loglike;
          arcs_out_data[oarc_idx0123] = arc;

          // We won't preduce arc_map_b (for nnet_output) for online_decoding,
          // in this case, b_fsas_ is only a part of the whole sequence.
          if (!online_decoding) {
            int32_t fsa_id = oarc_idx0,
              b_fsas_idx0x = b_fsas_row_splits1[fsa_id],
              b_fsas_idx01 = b_fsas_idx0x + t,
              // Use arc_label instead of arc.label to keep track of
              // the origial arc index in b_fsas when allow_partial == true.
              // Then arc_map_b storages the "correct" arc index instead of
              // the non-exist manually added arc pointing to super-final state.
              b_fsas_idx2 = (arc_label + 1),
              b_fsas_arc_idx012 = b_fsas_idx01 * b_fsas_num_cols + b_fsas_idx2;
              arc_map_b_data[oarc_idx0123] = b_fsas_arc_idx012;
          }
          arc_map_a_data[oarc_idx0123] = arc_info.a_fsas_arc_idx012;
        });

    // Remove axis 1, which corresponds to time.
    *ofsa = FsaVec(RemoveAxis(oshape, 1), arcs_out);
  }

  /*
    Computes pruning cutoffs for this frame: these are the cutoffs for the arc
    "forward score", one per FSA.  This is a dynamic process involving
    dynamic_beams_ which are updated on each frame (they start off at
    search_beam_).

       @param [in] arc_end_scores  The "forward log-probs" (scores) at the
                    end of each arc, i.e. its contribution to the following
                    state.  Is a tensor indexed [fsa_id][state][arc]; we
                    will get rid of the [state] dim, combining it with the
                    [arc] dim, so it's just [fsa_id][arc]
                    It is conceptually unchanged by this operation but non-const
                    because row-ids of its shape may need to be generated.
       @param [in] t  Which frame we are processing (i.e. the frame index).
       @return      Returns a vector of log-likelihood cutoffs, one per FSA (the
                    cutoff will be -infinity for FSAs that don't have any active
                    states).  The cutoffs will be of the form: the best score
                    for any arc, minus the dynamic beam.  See the code for how
                    the dynamic beam is adjusted; it will approach
                    'search_beam_' as long as the number of active states in
                    each FSA is between min_active and max_active.
  */
  Array1<float> GetPruningCutoffs(Ragged<float> &arc_end_scores, int32_t t) {
    NVTX_RANGE(K2_FUNC);
    int32_t num_fsas = arc_end_scores.shape.Dim0();

    // get the maximum score from each sub-list (i.e. each FSA, on this frame).
    // Note: can probably do this with a cub Reduce operation using an operator
    // that has side effects (that notices when it's operating across a
    // boundary).
    // the max will be -infinity for any FSA-id that doesn't have any active
    // states (e.g. because that stream has finished).
    // Casting to ragged2 just considers the top 2 indexes, ignoring the 3rd.
    // i.e. it's indexed by [fsa_id][arc].
    Ragged<float> end_scores_per_fsa = arc_end_scores.RemoveAxis(1);
    Array1<float> max_per_fsa(c_, end_scores_per_fsa.Dim0());
    MaxPerSublist(end_scores_per_fsa, -std::numeric_limits<float>::infinity(),
                  &max_per_fsa);
    const int32_t *arc_end_scores_row_splits1_data =
        arc_end_scores.RowSplits(1).Data();
    const float *max_per_fsa_data = max_per_fsa.Data();
    float *dynamic_beams_data = dynamic_beams_.Data();

    float default_beam = search_beam_, max_active = max_active_,
          min_active = min_active_;
    K2_CHECK_LT(min_active, max_active);

    const int32_t *b_fsas_row_splits1 = b_fsas_->shape.RowSplits(1).Data();

    Array1<float> cutoffs(c_, num_fsas);
    float *cutoffs_data = cutoffs.Data();

    bool online_decoding = online_decoding_;
    K2_EVAL(
        c_, num_fsas, lambda_set_beam_and_cutoffs, (int32_t i)->void {
          float best_loglike = max_per_fsa_data[i],
                dynamic_beam = dynamic_beams_data[i];
          int32_t active_states = arc_end_scores_row_splits1_data[i + 1] -
                                  arc_end_scores_row_splits1_data[i],
                  final_t = b_fsas_row_splits1[i+1] - b_fsas_row_splits1[i];
          float current_min_active = min_active;
          // Do less pruning on the few final frames, to ensure we don't prune
          // away final states.
          if (!online_decoding && t + 5 >= final_t) {
              current_min_active = max(min_active, max_active / 2);
          }
          if (active_states <= max_active) {
            // Not constrained by max_active...
            if (active_states >= current_min_active || active_states == 0) {
              // Neither the max_active nor min_active constraints
              // apply.  Gradually approach 'beam'
              // (Also approach 'beam' if active_states == 0; we might as
              // well, since there is nothing to prune here).
              dynamic_beam = 0.8 * dynamic_beam + 0.2 * default_beam;
            } else {
              // We violated the min_active constraint -> increase beam
              if (dynamic_beam < default_beam) dynamic_beam = default_beam;
              // gradually make the beam larger as long
              // as we are below min_active
              dynamic_beam *= 1.25;
            }
          } else {
            // We modify dynamic_beam when max_active violated only if it's not
            // last few frames, in order to avoid final states pruning.
            if (online_decoding || t + 5 < final_t) {
              // We violated the max_active constraint -> decrease beam
              if (dynamic_beam > default_beam) dynamic_beam = default_beam;

              // Decrease the beam as long as we have more than
              // max_active active states.
              dynamic_beam *= 0.8;
            }
          }
          // no pruning on last frame; we want all final-arcs.
          // -1 because t starts from 0.
          if (!online_decoding && t == final_t - 1) dynamic_beam = 1.0e+10;

          dynamic_beams_data[i] = dynamic_beam;
          cutoffs_data[i] = best_loglike - dynamic_beam;
        });

    return cutoffs;
  }

  /*
    Returns list of arcs on this frame, consisting of all arcs leaving
    the states active on 'cur_frame'.

       @param [in] t       The time-index (on which to look up log-likes),
                           t >= 0
       @param [in] cur_frame   The FrameInfo for the current frame; only its
                       'states' member is expected to be set up on entry.
   */
  Ragged<ArcInfo> GetArcs(int32_t t, FrameInfo *cur_frame) {
    NVTX_RANGE(K2_FUNC);
    Ragged<StateInfo> &states = cur_frame->states;
    const StateInfo *state_values = states.values.Data();

    // in a_fsas_ (the decoding graphs), maps from state_idx01 to arc_idx01x.
    const int32_t *fsa_arc_splits = a_fsas_.shape.RowSplits(2).Data();

    int32_t num_states = states.values.Dim();
    Array1<int32_t> num_arcs(c_, num_states + 1);
    int32_t *num_arcs_data = num_arcs.Data();
    // `num_arcs` gives the num-arcs for each state in `states`.
    K2_EVAL(
        c_, num_states, num_arcs_lambda, (int32_t state_idx01)->void {
          int32_t a_fsas_state_idx01 =
                      state_values[state_idx01].a_fsas_state_idx01,
                  a_fsas_arc_idx01x = fsa_arc_splits[a_fsas_state_idx01],
                  a_fsas_arc_idx01x_next =
                      fsa_arc_splits[a_fsas_state_idx01 + 1],
                  a_fsas_num_arcs = a_fsas_arc_idx01x_next - a_fsas_arc_idx01x;
          num_arcs_data[state_idx01] = a_fsas_num_arcs;
        });
    ExclusiveSum(num_arcs, &num_arcs);

    // initialize shape of array that will hold arcs leaving the active states.
    // Its shape is [fsa_index][state][arc]; the top two levels are shared with
    // `states`.  'ai' means ArcInfo.
    RaggedShape ai_shape =
        ComposeRaggedShapes(states.shape, RaggedShape2(&num_arcs, nullptr, -1));

    // from state_idx01 (into `states` or `ai_shape`) -> fsa_idx0
    const int32_t *ai_row_ids1 = ai_shape.RowIds(1).Data();
    // from arc_idx012 (into `ai_shape`) to state_idx01
    const int32_t *ai_row_ids2 = ai_shape.RowIds(2).Data();
    // from state_idx01 to arc_idx01x
    const int32_t *ai_row_splits2 = ai_shape.RowSplits(2).Data();

    const int32_t *a_fsas_row_splits1 = a_fsas_.shape.RowSplits(1).Data();
    const int32_t *a_fsas_row_ids1 = a_fsas_.shape.RowIds(1).Data();
    // from state_idx01 (into a_fsas_) to arc_idx01x (into a_fsas_)
    const int32_t *a_fsas_row_splits2 = a_fsas_.shape.RowSplits(2).Data();

    const Arc *arcs = a_fsas_.values.Data();
    // fsa_idx0 to idx0x (into b_fsas_), which gives the 1st row for this
    // sequence.
    const int32_t *b_fsas_row_ids1 = b_fsas_->shape.RowIds(1).Data();
    const int32_t *b_fsas_row_splits1 = b_fsas_->shape.RowSplits(1).Data();
    const float *score_data = b_fsas_->scores.Data();
    int32_t scores_num_cols = b_fsas_->scores.Dim1();
    auto scores_acc = b_fsas_->scores.Accessor();

    Ragged<ArcInfo> ai(ai_shape);
    ArcInfo *ai_data = ai.values.Data();  // uninitialized

    // A valid final arc means its label == -1.
    auto has_valid_final_arc = Array1<bool>(c_, NumFsas(), false);
    bool *has_valid_final_arc_data = has_valid_final_arc.Data();
    bool allow_partial = allow_partial_;

    if (allow_partial_) {
      K2_EVAL(
         c_, ai.values.Dim(), set_has_non_inf_arc, (int32_t ai_arc_idx012)->void {
           int32_t ai_state_idx01 = ai_row_ids2[ai_arc_idx012],
                   ai_fsa_idx0 = ai_row_ids1[ai_state_idx01],
                   ai_arc_idx01x = ai_row_splits2[ai_state_idx01],
                   ai_arc_idx2 = ai_arc_idx012 - ai_arc_idx01x;
           StateInfo sinfo = state_values[ai_state_idx01];
           int32_t a_fsas_arc_idx01x =
                       a_fsas_row_splits2[sinfo.a_fsas_state_idx01],
                   a_fsas_arc_idx012 = a_fsas_arc_idx01x + ai_arc_idx2;
           Arc arc = arcs[a_fsas_arc_idx012];
           auto final_t = b_fsas_row_splits1[ai_fsa_idx0+1] - b_fsas_row_splits1[ai_fsa_idx0];
           if (final_t - 1 == t && -1 == arc.label) {
             has_valid_final_arc_data[ai_fsa_idx0] = true;
           }
         });
    }

    K2_EVAL(
        c_, ai.values.Dim(), ai_lambda, (int32_t ai_arc_idx012)->void {
          int32_t ai_state_idx01 = ai_row_ids2[ai_arc_idx012],
                  ai_fsa_idx0 = ai_row_ids1[ai_state_idx01],
                  ai_arc_idx01x = ai_row_splits2[ai_state_idx01],
                  ai_arc_idx2 = ai_arc_idx012 - ai_arc_idx01x;
          StateInfo sinfo = state_values[ai_state_idx01];
          int32_t a_fsas_arc_idx01x =
                      a_fsas_row_splits2[sinfo.a_fsas_state_idx01],
                  a_fsas_arc_idx012 = a_fsas_arc_idx01x + ai_arc_idx2;
          Arc arc = arcs[a_fsas_arc_idx012];

          int32_t scores_idx0x = b_fsas_row_splits1[ai_fsa_idx0],
                  scores_idx01 = scores_idx0x + t,  // t == idx1 into 'scores'
              scores_idx2 =
                  arc.label + 1;  // the +1 is so that -1 can be handled
          K2_DCHECK_LT(static_cast<uint32_t>(scores_idx2),
                       static_cast<uint32_t>(scores_num_cols));
          float acoustic_score = scores_acc(scores_idx01, scores_idx2);
          auto dest_state = arc.dest_state;
          auto final_t = b_fsas_row_splits1[ai_fsa_idx0+1] - b_fsas_row_splits1[ai_fsa_idx0];

          if (final_t - 1 == t &&
              (allow_partial && !has_valid_final_arc_data[ai_fsa_idx0])) {
              int32_t a_fsas_idx0 = a_fsas_row_ids1[sinfo.a_fsas_state_idx01];
              // state_idx1 is 0-based.
              // So "-1" is used when calculating a_fsas_final_state_idx1.
              int32_t a_fsas_final_state_idx1
                = a_fsas_row_splits1[a_fsas_idx0 + 1] - 1 - a_fsas_row_splits1[a_fsas_idx0];
              dest_state = a_fsas_final_state_idx1;
              acoustic_score = 0.0;
          }
          ArcInfo ai;
          ai.a_fsas_arc_idx012 = a_fsas_arc_idx012;
          ai.arc_loglike = acoustic_score + arc.score;
          ai.end_loglike =
              OrderedIntToFloat(sinfo.forward_loglike) + ai.arc_loglike;
          // at least currently, the ArcInfo object's src_state and dest_state
          // are idx1's not idx01's, i.e. they don't contain the FSA-index,
          // where as the ai element is an idx01, so we need to do this to
          // convert to an idx01; this relies on the fact that
          // sinfo.abs_state_id == arc.src_state + a_fsas_fsa_idx0x.
          ai.u.dest_a_fsas_state_idx01 =
              sinfo.a_fsas_state_idx01 + dest_state - arc.src_state;
          ai_data[ai_arc_idx012] = ai;
        });
    return ai;
  }

  // Later we may choose to support b_fsas_->Dim0() == 1 and a_fsas_.Dim0() > 1,
  // and we'll have to change various bits of code for that to work.
  inline int32_t NumFsas() const { return b_fsas_->shape.Dim0(); }

  /*
    Does the forward-propagation (basically: the decoding step) and
    returns a newly allocated FrameInfo* object for the next frame.

      num_key_bits (template argument): either 32 (normal case) or 40: it is
            the number number of bits in `state_map_idx`.

      @param [in] t   Time-step that we are processing arcs leaving from;
                   will be called with t=0, t=1, ...
      @param [in] cur_frame  FrameInfo object for the states corresponding to
                   time t; will have its 'states' member set up but not its
                   'arcs' member (this function will create that).
     @return  Returns FrameInfo object corresponding to time t+1; will have its
             'states' member set up but not its 'arcs' member.
   */
  template <int32_t NUM_KEY_BITS>
  std::unique_ptr<FrameInfo> PropagateForward(int32_t t, FrameInfo *cur_frame) {
    NVTX_RANGE("PropagateForward");
    int32_t num_fsas = NumFsas();
    // Ragged<StateInfo> &states = cur_frame->states;
    // arc_info has 3 axes: fsa_id, state, arc.
    cur_frame->arcs = GetArcs(t, cur_frame);

    if (NUM_KEY_BITS > 32) { // a check.
      constexpr int32_t NUM_VALUE_BITS = 64 - NUM_KEY_BITS,
                             shift = std::min<int32_t>(31, NUM_VALUE_BITS);
      // the 'min' part is to avoid a compiler warning about 'shift count too
      // large' for code that is anyway unreachable.
      K2_CHECK_EQ(cur_frame->arcs.NumElements() >> shift, 0) <<
          "Too many arcs to store in hash; try smaller NUM_KEY_BITS (would "
          "require code change) or reduce max_states or minibatch size.";
    }

    Ragged<ArcInfo> &arc_info = cur_frame->arcs;

    ArcInfo *ai_data = arc_info.values.Data();
    Array1<float> ai_data_array1(c_, cur_frame->arcs.values.Dim());
    float *ai_data_array1_data = ai_data_array1.Data();
    K2_EVAL(
        c_, ai_data_array1.Dim(), lambda_set_ai_data,
        (int32_t i)->void { ai_data_array1_data[i] = ai_data[i].end_loglike; });
    Ragged<float> ai_loglikes(arc_info.shape, ai_data_array1);

    // `cutoffs` is of dimension num_fsas.
    Array1<float> cutoffs = GetPruningCutoffs(ai_loglikes, t);
    float *cutoffs_data = cutoffs.Data();

    // write certain indexes (into ai.values) to state_map_.Data().  Keeps
    // track of the active states and will allow us to assign a numbering to
    // them.
    const int32_t *ai_row_ids1 = arc_info.shape.RowIds(1).Data(),
                  *ai_row_ids2 = arc_info.shape.RowIds(2).Data();
    int64_t state_map_fsa_stride = state_map_fsa_stride_;

    // renumber_states will be a renumbering that dictates which of the arcs in
    // 'ai' correspond to unique states.  Only one arc for each dest-state is
    // kept (it doesn't matter which one).
    Renumbering renumber_states(c_, arc_info.NumElements());
    char *keep_this_state_data = renumber_states.Keep().Data();

    int32_t new_hash_size = RoundUpToNearestPowerOfTwo(
        int32_t(arc_info.NumElements() * 1.0));
    if (new_hash_size > state_map_.NumBuckets()) {
      bool copy_data = false;  // The hash is empty right now, so there is
                               // nothing to copy.
      state_map_.Resize(new_hash_size, NUM_KEY_BITS, -1, copy_data);
    }

    auto state_map_acc = state_map_.GetAccessor<Hash::Accessor<NUM_KEY_BITS>>();

    {
      NVTX_RANGE("LambdaSetStateMap");
      K2_EVAL(
          c_, arc_info.NumElements(), lambda_set_state_map,
          (int32_t arc_idx012)->void {
            int32_t fsa_id = ai_row_ids1[ai_row_ids2[arc_idx012]];
            int32_t dest_state_idx01 =
                ai_data[arc_idx012].u.dest_a_fsas_state_idx01;
            float end_loglike = ai_data[arc_idx012].end_loglike,
                  cutoff = cutoffs_data[fsa_id];
            char keep_this_state = 0;  // only one arc entering any state will
                                       // have its 'keep_this_state_data' entry
                                       // set to 1.
            if (end_loglike > cutoff) {
              uint64_t state_map_idx = dest_state_idx01 +
                          fsa_id * state_map_fsa_stride;
              if (state_map_acc.Insert(state_map_idx, (uint64_t)arc_idx012))
                keep_this_state = 1;
            }
            keep_this_state_data[arc_idx012] = keep_this_state;
          });
    }


    int32_t num_states = renumber_states.NumNewElems();
    // state_reorder_data maps from (state_idx01 on next frame) to (the
    // arc_idx012 on this frame which is the source arc which we arbitrarily
    // choose as being "responsible" for the creation of that state).
    const int32_t *state_reorder_data = renumber_states.Old2New().Data();

    // state_to_fsa_id maps from an index into the next frame's
    // FrameInfo::states.values() vector to the sequence-id (fsa_id) associated
    // with it.  It should be non-decreasing.
    Array1<int32_t> state_to_fsa_id(c_, num_states);
    {  // This block sets 'state_to_fsa_id'.
      NVTX_RANGE("LambdaSetStateToFsaId");
      int32_t *state_to_fsa_id_data = state_to_fsa_id.Data();
      K2_EVAL(
          c_, arc_info.NumElements(), lambda_state_to_fsa_id,
          (int32_t arc_idx012)->void {
            int32_t fsa_id = ai_row_ids1[ai_row_ids2[arc_idx012]],
                    this_state_j = state_reorder_data[arc_idx012],
                    next_state_j = state_reorder_data[arc_idx012 + 1];
            if (next_state_j > this_state_j) {
              state_to_fsa_id_data[this_state_j] = fsa_id;
            }
          });

      K2_DCHECK(IsMonotonic(state_to_fsa_id));
    }

    std::unique_ptr<FrameInfo> ans = std::make_unique<FrameInfo>();
    Array1<int32_t> states_row_splits1(c_, num_fsas + 1);
    RowIdsToRowSplits(state_to_fsa_id, &states_row_splits1);
    ans->states = Ragged<StateInfo>(
        RaggedShape2(&states_row_splits1, &state_to_fsa_id, num_states),
        Array1<StateInfo>(c_, num_states));
    StateInfo *ans_states_data = ans->states.values.Data();
    const int32_t minus_inf_int =
        FloatToOrderedInt(-std::numeric_limits<float>::infinity());
    K2_EVAL(
        c_, num_states, lambda_init_loglike, (int32_t i)->void {
          ans_states_data[i].forward_loglike = minus_inf_int;
        });

    {
      NVTX_RANGE("LambdaModifyStateMap");
      // Modify the elements of `state_map` to refer to the indexes into
      // `ans->states` / `kept_states_data`, rather than the indexes into
      // ai_data. This will decrease some of the values in `state_map`, in
      // general.
      K2_EVAL(
          c_, arc_info.NumElements(), lambda_modify_state_map,
          (int32_t arc_idx012)->void {
            int32_t fsa_id = ai_row_ids1[ai_row_ids2[arc_idx012]];
            int32_t dest_state_idx01 =
                ai_data[arc_idx012].u.dest_a_fsas_state_idx01;
            int32_t this_j = state_reorder_data[arc_idx012],
                    next_j = state_reorder_data[arc_idx012 + 1];
            if (next_j > this_j) {
              uint64_t state_map_idx = dest_state_idx01 +
                                      fsa_id * state_map_fsa_stride;
              uint64_t value, *key_value_addr = nullptr;
              bool ans = state_map_acc.Find(state_map_idx,
                                            &value, &key_value_addr);
              K2_DCHECK(ans);
              K2_DCHECK_EQ(static_cast<int32_t>(value), arc_idx012);
              // Note: this_j is an idx01 into ans->states.  previously it
              // contained an arc_idx012 (of the entering arc that won the
              // race).
              state_map_acc.SetValue(key_value_addr, state_map_idx,
                                     (uint64_t)this_j);
            }
          });
    }

    // We'll set up the data of the kept states below...
    StateInfo *kept_states_data = ans->states.values.Data();

    {
      int32_t *ans_states_row_splits1_data = ans->states.RowSplits(1).Data();

      NVTX_RANGE("LambdaSetStates");
      K2_EVAL(
          c_, arc_info.NumElements(), lambda_set_arcs_and_states,
          (int32_t arc_idx012)->void {
            int32_t fsa_id = ai_row_ids1[ai_row_ids2[arc_idx012]];

            ArcInfo &info = ai_data[arc_idx012];

            int32_t dest_a_fsas_state_idx01 = info.u.dest_a_fsas_state_idx01;

            uint64_t state_map_idx = dest_a_fsas_state_idx01 +
                                     fsa_id * state_map_fsa_stride;
            uint64_t state_idx01;
            const uint64_t minus_one = ~(uint64_t)0;
            if (!state_map_acc.Find(state_map_idx, &state_idx01))
              state_idx01 = minus_one;   // The destination state did not survive
                                         // pruning.

            int32_t state_idx1;
            if (state_idx01 != minus_one) {
              int32_t state_idx0x = ans_states_row_splits1_data[fsa_id];
              state_idx1 = static_cast<int32_t>(state_idx01) - state_idx0x;
            } else {
              state_idx1 = -1;  // Meaning: invalid.
            }
            // state_idx1 is the idx1 into ans->states, of the destination
            // state.
            info.u.dest_info_state_idx1 = state_idx1;
            if (state_idx1 < 0)
              return;

            // multiple threads may write the same value to the address written
            // to in the next line.
            kept_states_data[state_idx01].a_fsas_state_idx01 =
                dest_a_fsas_state_idx01;
            int32_t end_loglike_int = FloatToOrderedInt(info.end_loglike);
            // Set the forward log-like of the dest state to the largest of any
            // of those of the incoming arcs.  Note: we initialized this in
            // lambda_init_loglike above.
            AtomicMax(&(kept_states_data[state_idx01].forward_loglike),
                      end_loglike_int);
          });
    }
    {
      NVTX_RANGE("LambdaResetStateMap");
      const int32_t *next_states_row_ids1 = ans->states.shape.RowIds(1).Data();
      K2_EVAL(
          c_, ans->states.NumElements(), lambda_reset_state_map,
          (int32_t state_idx01)->void {
            int32_t a_fsas_state_idx01 =
                        kept_states_data[state_idx01].a_fsas_state_idx01,
                fsa_idx0 = next_states_row_ids1[state_idx01];
            int64_t state_map_idx = a_fsas_state_idx01 +
                                    fsa_idx0 * state_map_fsa_stride;
            state_map_acc.Delete(state_map_idx);
          });
    }
    return ans;
  }


  /*
    Sets backward_loglike fields of StateInfo to the negative of the forward
    prob if (this is the final-state or !only_final_probs), else -infinity.

    This is used in computing the backward loglikes/scores for purposes of
    pruning.  This may be done after we're finished decoding/intersecting,
    or while we are still decoding.

    Note: something similar to this (setting backward-prob == forward-prob) is
    also done in PropagateBackward() when we detect final-states.  That's needed
    because not all sequences have the same length, so some may have reached
    their final state earlier.  (Note: we only get to the final-state of a_fsas_
    if we've reached the final frame of the input, because for non-final frames
    we always have -infinity as the log-prob corresponding to the symbol -1.)

    While we are still decoding, a background process will do pruning
    concurrently with the forward computation, for purposes of reducing memory
    usage (and so that most of the pruning can be made concurrent with the
    forward computation).  In this case we want to avoid pruning away anything
    that wouldn't have been pruned away if we were to have waited to the end;
    and it turns out that setting the backward probs to the negative of the
    forward probs (i.e.  for all states, not just final states) accomplishes
    this.  The issue was mentioned in the "Exact Lattice Generation.." paper and
    also in the code for Kaldi's lattice-faster-decoder; search for "As in [3],
    to save memory..."

      @param [in] cur_frame    Frame on which to set the backward probs
  */
  void SetBackwardProbsFinal(FrameInfo *cur_frame) {
    NVTX_RANGE("SetBackwardProbsFinal");
    Ragged<StateInfo> &cur_states = cur_frame->states;  // 2 axes: fsa,state
    int32_t num_states = cur_states.values.Dim();
    if (num_states == 0)
      return;
    StateInfo *cur_states_data = cur_states.values.Data();
    const int32_t *a_fsas_row_ids1_data = a_fsas_.shape.RowIds(1).Data(),
               *a_fsas_row_splits1_data = a_fsas_.shape.RowSplits(1).Data(),
              *cur_states_row_ids1_data = cur_states.RowIds(1).Data();
    double minus_inf = -std::numeric_limits<double>::infinity();

    K2_EVAL(c_, num_states, lambda_set_backward_prob, (int32_t state_idx01) -> void {
        StateInfo *info = cur_states_data + state_idx01;
        double backward_loglike,
            forward_loglike = OrderedIntToFloat(info->forward_loglike);
        if (forward_loglike - forward_loglike == 0) { // not -infinity...
          // canonically we'd set this to zero, but setting it to the forward
          // loglike when this is the final-state (in a_fsas_) has the effect of
          // making the (forward+backward) probs equivalent to the logprob minus
          // the best-path log-prob, which is convenient for pruning.  If this
          // is not actually the last frame of this sequence, which can happen
          // if this was called before the forward decoding process was
          // finished, what we are doing is a form of pruning that is guaranteed
          // not to prune anything out that would not have been pruned out if we
          // had waited until the real end of the file to do the pruning.
          backward_loglike = -forward_loglike;
        } else {
          backward_loglike = minus_inf;
        }
        info->backward_loglike = backward_loglike;
      });
  }

  /*
    Does backward propagation of log-likes, which means setting the
    backward_loglike field of the StateInfo variable (for cur_frame);
    and works out which arcs and which states are to be pruned
    on cur_frame; this information is output to Array1<char>'s which
    are supplied by the caller.

    These backward log-likes are normalized in such a way that you can add them
    with the forward log-likes to produce the log-likelihood ratio vs the best
    path (this will be non-positive).  (To do this, for the final state we have
    to set the backward log-like to the negative of the forward log-like; see
    SetBackwardProbsFinal()).

    This function also prunes arc-indexes on `cur_frame` and state-indexes
    on `next_frame`.

       @param [in] t      The time-index (on which to look up log-likes);
                          equals time index of `cur_frame`; t >= 0
       @param [in]  cur_frame The FrameInfo for the frame on which we want to
                          set the forward log-like, and output pruning info
                          for arcs and states
       @param [in]  next_frame The next frame's FrameInfo, on which to look
                           up log-likes for the next frame; the
                           `backward_loglike` values of states on `next_frame`
                           are assumed to already be set, either by
                           SetBackwardProbsFinal() or a previous call to
                           PropagateBackward().
       @param [out] cur_frame_states_keep   An array, created by the caller,
                        to which we'll write 1s for elements of cur_frame->states
                        which we need to keep, and 0s for others.
       @param [out] cur_frame_arcs_keep   An array, created by the caller,
                        to which we'll write 1s for elements of cur_frame->arcs
                        which we need to keep (because they survived pruning),
                        and 0s for others.
  */
  void PropagateBackward(int32_t t,
                         FrameInfo *cur_frame,
                         FrameInfo *next_frame,
                         Array1<char> *cur_frame_states_keep,
                         Array1<char> *cur_frame_arcs_keep) {
    NVTX_RANGE("PropagateBackward");
    int32_t num_states = cur_frame->states.NumElements(),
            num_arcs = cur_frame->arcs.NumElements();
    K2_CHECK_EQ(num_states, cur_frame_states_keep->Dim());
    K2_CHECK_EQ(num_arcs, cur_frame_arcs_keep->Dim());

    int32_t *a_fsas_row_ids1_data = a_fsas_.shape.RowIds(1).Data(),
            *a_fsas_row_splits1_data = a_fsas_.shape.RowSplits(1).Data();

    float minus_inf = -std::numeric_limits<float>::infinity();

    Ragged<float> arc_backward_prob(cur_frame->arcs.shape,
                                    Array1<float>(c_, cur_frame->arcs.NumElements()));
    float *arc_backward_prob_data = arc_backward_prob.values.Data();

    ArcInfo *ai_data = cur_frame->arcs.values.Data();
    int32_t *arcs_rowids1 = cur_frame->arcs.shape.RowIds(1).Data(),
            *arcs_rowids2 = cur_frame->arcs.shape.RowIds(2).Data(),
            *arcs_row_splits1 = cur_frame->arcs.shape.RowSplits(1).Data(),
            *arcs_row_splits2 = cur_frame->arcs.shape.RowSplits(2).Data();
    float output_beam = output_beam_;

    // compute arc backward probs, and set elements of 'keep_cur_arcs_data'
    int32_t next_num_states = next_frame->states.TotSize(1);

    char *keep_cur_arcs_data = cur_frame_arcs_keep->Data(),
        *keep_cur_states_data = cur_frame_states_keep->Data();

    const int32_t *next_states_row_splits1_data =
        next_frame->states.RowSplits(1).Data();

    StateInfo *next_states_data = next_frame->states.values.Data();
    StateInfo *cur_states_data = cur_frame->states.values.Data();

    K2_EVAL(c_, num_arcs, lambda_set_arc_backward_prob_and_keep,
            (int32_t arcs_idx012) -> void {
      ArcInfo *arc = ai_data + arcs_idx012;
      int32_t state_idx01 = arcs_rowids2[arcs_idx012],
                 seq_idx0 = arcs_rowids1[state_idx01],  // 'seq' == fsa-idx in b
        next_states_idx0x = next_states_row_splits1_data[seq_idx0];

      // Note: if dest_state_idx1 == -1, dest_state_idx01 has a meaningless
      // value below, but it's never referenced.
      int32_t dest_state_idx1 = arc->u.dest_info_state_idx1,
             dest_state_idx01 = next_states_idx0x + dest_state_idx1;
      float backward_loglike = minus_inf;
      char keep_this_arc = 0;
      if (dest_state_idx1 == -1) {
          // dest_state_idx1 == -1 means this arc was already pruned in
          // the forward pass.. do nothing.
      } else {
        float arc_loglike = arc->arc_loglike;
        float dest_state_backward_loglike =
            next_states_data[dest_state_idx01].backward_loglike;
        // 'backward_loglike' is the loglike at the beginning of the arc
        backward_loglike = arc_loglike + dest_state_backward_loglike;
        float src_state_forward_loglike = OrderedIntToFloat(
            cur_states_data[arcs_rowids2[arcs_idx012]].forward_loglike);

        // should be <= 0.0, mathematically.
        K2_CHECK_LE(backward_loglike, -src_state_forward_loglike + 2.0);
        if (backward_loglike + src_state_forward_loglike >= -output_beam) {
          keep_this_arc = 1;
        } else {
          backward_loglike = minus_inf;  // Don't let arcs outside beam
                                         // contribute to their start-states's
                                         // backward prob (we'll use that to
                                         // prune the start-states away.)
        }
      }
      keep_cur_arcs_data[arcs_idx012] = keep_this_arc;
      arc_backward_prob_data[arcs_idx012] = backward_loglike;
      });

    /* note, the elements of state_backward_prob that don't have arcs leaving
       them will be set to the supplied default.  */
    Array1<float> state_backward_prob(c_, num_states);
    MaxPerSublist(arc_backward_prob, minus_inf, &state_backward_prob);

    const float *state_backward_prob_data = state_backward_prob.Data();
    const int32_t *cur_states_row_ids1 =
        cur_frame->states.shape.RowIds(1).Data();

    int32_t num_fsas = NumFsas();
    K2_DCHECK_EQ(cur_frame->states.shape.Dim0(), num_fsas);
    K2_EVAL(
        c_, cur_frame->states.NumElements(), lambda_set_state_backward_prob,
        (int32_t state_idx01)->void {
          StateInfo *info = cur_states_data + state_idx01;
          int32_t fsas_state_idx01 = info->a_fsas_state_idx01,
                  a_fsas_idx0 = a_fsas_row_ids1_data[fsas_state_idx01],
                  fsas_state_idx0x_next = a_fsas_row_splits1_data[a_fsas_idx0 + 1];
          float forward_loglike = OrderedIntToFloat(info->forward_loglike),
                backward_loglike;
          // `is_final_state` means this is the final-state in a_fsas.  this
          // implies it's final in b_fsas too, since they both would have seen
          // symbols -1.
          int32_t is_final_state =
              (fsas_state_idx01 + 1 >= fsas_state_idx0x_next);
          if (is_final_state) {
            // Note: there is only one final-state.
            backward_loglike = -forward_loglike;
          } else {
            backward_loglike = state_backward_prob_data[state_idx01];
          }
          info->backward_loglike = backward_loglike;
          keep_cur_states_data[state_idx01] = (backward_loglike != minus_inf);
        });
  }

  /*
    This function does backward propagation and pruning of arcs and states for a
    specific time range.
        @param [in] begin_t   Lowest `t` value to call PropagateBackward() for
                            and to prune its arcs and states.  Require t >= 0.
        @param [in] end_t    One-past-the-highest `t` value to call PropagateBackward()
                            and to prune its arcs and states.  Require that
                            `frames_[t+1]` already be set up; this requires at least
                            end_t <= T.
    Arcs on frames t >= end_t and states on frame t > end_t are ignored; the backward
    probs on time end_t are set by SetBackwardProbsFinal(), see its documentation
    to understand what this does if we haven't yet reached the end of one of the
    sequences.

    After this function is done, the arcs for `frames_[t]` with begin_t <= t < end_t and
    the states for `frames_[t]` with begin_t < t < end_t will have their numbering changed.
    (We don't renumber the states on begin_t because that would require the dest-states
     of the arcs on time `begin_t - 1` to be modified).  TODO: check this...
   */
  void PruneTimeRange(int32_t begin_t,
                      int32_t end_t) {
    NVTX_RANGE(K2_FUNC);
    SetBackwardProbsFinal(frames_[end_t].get());
    ContextPtr cpu = GetCpuContext();
    int32_t num_fsas = b_fsas_->shape.Dim0(),
               num_t = end_t - begin_t;
    Array1<int32_t> old_states_offsets(cpu, num_t + 1),
        old_arcs_offsets(cpu, num_t + 1);
    int32_t tot_states = 0, tot_arcs = 0;
    {
      int32_t *old_states_offsets_data = old_states_offsets.Data(),
                *old_arcs_offsets_data = old_arcs_offsets.Data();
      for (int32_t i = 0; i <= num_t; i++) {
        int32_t t = begin_t + i;
        old_states_offsets_data[i] = tot_states;
        old_arcs_offsets_data[i] = tot_arcs;
        if (i < num_t) {
          tot_states += frames_[t]->arcs.TotSize(1);
          tot_arcs += frames_[t]->arcs.TotSize(2);
        }
      }
    }


    // contains respectively: row_splits1_ptrs, row_ids1_ptrs,
    // row_splits2_ptrs, row_ids2_ptrs,
    // old_arcs_ptrs (really type ArcInfo*),
    // old_states_ptrs (really type StateInfo*).
    Array1<void*> old_all_ptrs(cpu, num_t * 6);

    Renumbering renumber_states(c_, tot_states),
        renumber_arcs(c_, tot_arcs);
    {
      void                    **all_p = old_all_ptrs.Data();
      int32_t **old_row_splits1_ptrs_data = (int32_t**)all_p,
                 **old_row_ids1_ptrs_data = (int32_t**)all_p + num_t,
          **old_row_splits2_ptrs_data = (int32_t**)all_p + 2 * num_t,
             **old_row_ids2_ptrs_data = (int32_t**)all_p + 3 * num_t;
      StateInfo **old_states_ptrs_data = (StateInfo**)all_p + 4 * num_t;
      ArcInfo **old_arcs_ptrs_data = (ArcInfo**)all_p + 5 * num_t;
      int32_t *old_states_offsets_data = old_states_offsets.Data(),
                *old_arcs_offsets_data = old_arcs_offsets.Data();

      for (int32_t t = end_t - 1; t >= begin_t; --t) {
        int32_t i = t - begin_t;
        Array1<char> this_states_keep =
            renumber_states.Keep().Arange(old_states_offsets_data[i],
                                          old_states_offsets_data[i + 1]),
            this_arcs_keep =
            renumber_arcs.Keep().Arange(old_arcs_offsets_data[i],
                                        old_arcs_offsets_data[i + 1]);
        FrameInfo *cur_frame = frames_[t].get();
        PropagateBackward(t, cur_frame, frames_[t+1].get(),
                          &this_states_keep, &this_arcs_keep);

        old_row_splits1_ptrs_data[i] = cur_frame->arcs.RowSplits(1).Data();
        old_row_ids1_ptrs_data[i] = cur_frame->arcs.RowIds(1).Data();
        old_row_splits2_ptrs_data[i] = cur_frame->arcs.RowSplits(2).Data();
        old_row_ids2_ptrs_data[i] = cur_frame->arcs.RowIds(2).Data();
        old_arcs_ptrs_data[i] = cur_frame->arcs.values.Data();
        old_states_ptrs_data[i] = cur_frame->states.values.Data();

        // We can't discard any states on t == begin_t because: if it is not t ==
        // 0, it would be inconvenient to map the dest-states of arcs on t - 1;
        // and if it is t == 0, this may remove the start-state, which would make
        // it more complex to avoid invalid FSAs (e.g. with an end-state but no
        // start-state, or in which we incorrectly interpret a non-start state as
        // the start state).
        if (i == 0)  // t == begin_t
          this_states_keep = (char)1;  // set all elements of the array
        // `states_keep` to 1.
      }
    }

    old_states_offsets = old_states_offsets.To(c_);
    old_arcs_offsets = old_arcs_offsets.To(c_);
    Array1<int32_t> new_states_offsets = renumber_states.Old2New(true)[old_states_offsets],
                      new_arcs_offsets = renumber_arcs.Old2New(true)[old_arcs_offsets];
    int32_t new_num_states = renumber_states.NumNewElems(),
              new_num_arcs =  renumber_arcs.NumNewElems();
    // These arrays map to the (t - begin_t) corresponding to this state or arc
    // in the new numbering, i.e. the frame index minus begin_t.
    Array1<int32_t> new_state_to_frame(c_, new_num_states),
        new_arc_to_frame(c_, new_num_arcs);
    RowSplitsToRowIds(new_states_offsets, &new_state_to_frame);
    RowSplitsToRowIds(new_arcs_offsets, &new_arc_to_frame);
    const int32_t *old_states_offsets_data = old_states_offsets.Data(),
                  *new_states_offsets_data = new_states_offsets.Data(),
                    *old_arcs_offsets_data = old_arcs_offsets.Data(),
                    *new_arcs_offsets_data = new_arcs_offsets.Data(),
                  *new_state_to_frame_data = new_state_to_frame.Data(),
                    *new_arc_to_frame_data = new_arc_to_frame.Data(),
                      *states_old2new_data = renumber_states.Old2New().Data(),
                      *states_new2old_data = renumber_states.New2Old().Data(),
                        *arcs_old2new_data = renumber_arcs.Old2New().Data(),
                        *arcs_new2old_data = renumber_arcs.New2Old().Data();

    // Allocate the new row_splits and row_ids vectors for the shapes on the
    // individual frames, and the new arc-info and state-info.
    Array2<int32_t> all_row_splits1(c_, num_t, num_fsas + 1);
    auto all_row_splits1_acc = all_row_splits1.Accessor();
    Array1<int32_t> all_row_ids1(c_, new_num_states);
    // the "+ num_t" below is for the extra element of each row_splits array.
    Array1<int32_t> all_row_splits2(c_, new_num_states + num_t);
    Array1<int32_t> all_row_ids2(c_, new_num_arcs);
    Array1<StateInfo> all_states(c_, new_num_states);
    Array1<ArcInfo> all_arcs(c_, new_num_arcs);

    int32_t *all_row_ids1_data = all_row_ids1.Data(),
            *all_row_ids2_data = all_row_ids2.Data(),
         *all_row_splits2_data = all_row_splits2.Data();
    StateInfo *all_states_data = all_states.Data();
    ArcInfo *all_arcs_data = all_arcs.Data();

    old_all_ptrs = old_all_ptrs.To(c_);
    void **all_p = old_all_ptrs.Data();

    K2_EVAL2(c_, num_t, num_fsas + 1,
             lambda_set_new_row_splits1, (int32_t t_offset,
                                          int32_t seq_idx) -> void {
      // note, t_offset is t - t_start.
      int32_t *old_row_splits1 = (int32_t*) all_p[t_offset];
      int32_t old_idx0x = old_row_splits1[seq_idx];
      // "pos" means position in appended states vector
      // old_start_pos means start for this `t`.
      int32_t old_start_pos = old_states_offsets_data[t_offset],
                    old_pos = old_start_pos + old_idx0x,
              new_start_pos = states_old2new_data[old_start_pos],
                    new_pos = states_old2new_data[old_pos],
                  new_idx0x = new_pos - new_start_pos;
      all_row_splits1_acc(t_offset, seq_idx) = new_idx0x;
      // TODO: set elem zero of row-splits?

      if (seq_idx == 0) {
        // We assign the `seq_idx == 0` version of the kernel to set the initial
        // zero in each row_splits vector.
        all_row_splits2_data[new_pos + t_offset] = 0;
      }
             });

    K2_EVAL(c_, new_num_states, lambda_per_state, (int32_t new_i) -> void {
      // new_i is position in appended vector of all states.
      int32_t    t_offset = new_state_to_frame_data[new_i],
      old_state_start_pos = old_states_offsets_data[t_offset],
        new_arc_start_pos = new_arcs_offsets_data[t_offset],
        old_arc_start_pos = old_arcs_offsets_data[t_offset],
                    old_i = states_new2old_data[new_i],
          old_state_idx01 = old_i - old_state_start_pos;


      // this old_states_data is from its FrameInfo::states.
      const StateInfo *old_states_data = (StateInfo*)all_p[4 * num_t + t_offset];
      const int32_t *old_row_ids1_data = (int32_t*)all_p[1 * num_t + t_offset],
                 *old_row_splits2_data = (int32_t*)all_p[2 * num_t + t_offset];

      // set the row-ids1 (these contain FSA-ids).
      all_row_ids1_data[new_i] = old_row_ids1_data[old_state_idx01];


      {  // set the row-splits2.
        // We make each kernel responsible for the *next* row_splits entry,
        // i.e. for its new_state_idx01 plus one.  This solves the problem of no
        // kernel being responsible for the last row-splits entry.  We
        // separately wrote the zeros for the 1st row-splits entry, in a
        // previous kernel.
        //
        // It's safe to use old_state_idx01+1 instead of doing the same mapping
        // from new_i+1 that we do from new_i to old_state_idx01, because
        // we know this state was kept (because it has a new_i index.)
        int32_t old_arc_idx01x_next = old_row_splits2_data[old_state_idx01+1],
                   old_arc_pos_next = old_arc_idx01x_next + old_arc_start_pos,
                   new_arc_pos_next = arcs_old2new_data[old_arc_pos_next],
                new_arc_idx01x_next = new_arc_pos_next - new_arc_start_pos;

        // "+ t_offset" is to compensate for the extra element of each row_splits
        // vector.  The "+ 1" is about the "next", i.e. each kernel is responsible
        // for the next row_splits element, and none is responsible for the initial zero;
        // that is set in a previous kernel.
        all_row_splits2_data[new_i + t_offset + 1] = new_arc_idx01x_next;
      }
      all_states_data[new_i] = old_states_data[old_state_idx01];
      });

    K2_EVAL(c_, new_num_arcs, lambda_set_arcs, (int32_t new_i) -> void {
      // new_i is position in appended vector of all arcs
      int32_t    t_offset = new_arc_to_frame_data[new_i],
      new_state_start_pos = new_states_offsets_data[t_offset],
      old_state_start_pos = old_states_offsets_data[t_offset],
 next_old_state_start_pos = old_states_offsets_data[t_offset + 1],
        old_arc_start_pos = old_arcs_offsets_data[t_offset],
                    old_i = arcs_new2old_data[new_i],
           old_arc_idx012 = old_i - old_arc_start_pos;

      ArcInfo *old_info_data =  (ArcInfo*)all_p[5 * num_t + t_offset];
      int32_t *old_row_ids2_data = (int32_t*)all_p[3 * num_t + t_offset],
             *old_row_ids1_data  = (int32_t*)all_p[1 * num_t + t_offset],
      *next_old_row_splits1_data = (int32_t*)all_p[t_offset + 1];

      int32_t old_src_state_idx01 = old_row_ids2_data[old_arc_idx012],
                         fsa_idx0 = old_row_ids1_data[old_src_state_idx01],
                old_src_state_pos = old_src_state_idx01 + old_state_start_pos,
                new_src_state_pos = states_old2new_data[old_src_state_pos],
              new_src_state_idx01 = new_src_state_pos - new_state_start_pos;

      all_row_ids2_data[new_i] = new_src_state_idx01;

      ArcInfo info = old_info_data[old_arc_idx012];

      if (t_offset + 1 == num_t) {
        // Do nothing; this is the last frame of the batch of frames that we are
        // pruning, so we don't need to renumber the destination-states of the
        // arcs leaving it because the next frame's states have not been pruned
        // (so the numbering stays the same).
      } else {
        // idx1 of the state in the next frame's `states` object.
        int32_t dest_info_state_idx1 = info.u.dest_info_state_idx1;

        // the naming below is unusual; by "pos" we mean position in the old or
        // new "all_states" or "all_arcs" vectors, which have all frames appended.
        // (the new ones physically exist; the old ones don't, but they are the
        // numberings used in renumber_states.Keep() and renumber_arcs.Keep().)
        int32_t old_dest_state_idx0x = next_old_row_splits1_data[fsa_idx0],
        old_dest_state_idx01 = old_dest_state_idx0x + dest_info_state_idx1,
        old_dest_state_idx0x_pos = next_old_state_start_pos + old_dest_state_idx0x,
        old_dest_state_idx01_pos = next_old_state_start_pos + old_dest_state_idx01,
        new_dest_state_idx0x_pos = states_old2new_data[old_dest_state_idx0x_pos],
        new_dest_state_idx01_pos = states_old2new_data[old_dest_state_idx01_pos],
        new_dest_state_idx1 = new_dest_state_idx01_pos - new_dest_state_idx0x_pos;
        info.u.dest_info_state_idx1 = new_dest_state_idx1;
      }
      all_arcs_data[new_i] = info;
      });

    // Now reconstruct the states and arcs for all the frames we pruned, from
    // sub-parts of the arrays we just created.
    new_states_offsets = new_states_offsets.To(cpu);
    new_arcs_offsets = new_arcs_offsets.To(cpu);
    new_states_offsets_data = new_states_offsets.Data();
    new_arcs_offsets_data = new_arcs_offsets.Data();
    for (int32_t i = 0; i < num_t; i++) {  // i corresponds to "t_offset".
      int32_t state_offset = new_states_offsets_data[i],
         next_state_offset = new_states_offsets_data[i + 1],
                arc_offset = new_arcs_offsets_data[i],
           next_arc_offset = new_arcs_offsets_data[i + 1];

      // next line: operator[] into Array2 gives Array1, one row.
      Array1<int32_t> row_splits1 = all_row_splits1.Row(i),
                         row_ids1 = all_row_ids1.Arange(state_offset, next_state_offset),
                      row_splits2 = all_row_splits2.Arange(state_offset + i, next_state_offset + (i+1)),
                         row_ids2 = all_row_ids2.Arange(arc_offset, next_arc_offset);
      Array1<ArcInfo> arcs = all_arcs.Arange(arc_offset, next_arc_offset);

      RaggedShape arcs_shape = RaggedShape3(&row_splits1, &row_ids1, -1,
                                            &row_splits2, &row_ids2, -1);
      int32_t t = begin_t + i;
      frames_[t]->arcs = Ragged<ArcInfo>(arcs_shape, arcs);
      Array1<StateInfo> states = all_states.Arange(state_offset, next_state_offset);
      RaggedShape states_shape = GetLayer(arcs_shape, 0);
      frames_[t]->states = Ragged<StateInfo>(states_shape, states);
    }
  }

  const Array1<float>& GetBeams() {
    return dynamic_beams_;
  }

  ContextPtr c_;
  FsaVec &a_fsas_;         // Note: a_fsas_ has 3 axes.
  int32_t a_fsas_stride_;  // 1 if we use a different FSA per sequence
                           // (a_fsas_.Dim0() > 1), 0 if the decoding graph is
                           // shared (a_fsas_.Dim0() == 1).
  DenseFsaVec *b_fsas_;    // nnet_output to be decoded.
  int32_t num_seqs_;       // the number of sequences to decode at a time,
                           // i.e. batch size for decoding.
  int32_t T_;              // equals to b_fsas_->shape.MaxSize(1), for
                           // batch intersection.
                           // means the number of frames decoded currently.
  float search_beam_;
  float output_beam_;
  int32_t min_active_;
  int32_t max_active_;
  bool allow_partial_;
  Array1<float> dynamic_beams_;  // dynamic beams (initially just search_beam_
                                 // but change due to max_active/min_active
                                 // constraints).

  bool online_decoding_;         // true for online decoding.
  Array1<int32_t> final_t_;      // record the final frame id of each DenseFsa.
  std::unique_ptr<FrameInfo> partial_final_frame_;  // store the final frame for
                                                    // partial results

  int32_t state_map_fsa_stride_;  // state_map_fsa_stride_ is a_fsas_.TotSize(1)
                                  // if a_fsas_.Dim0() == 1, else 0.

  Hash state_map_;    // state_map_ maps from:
                      // key == (state_map_fsa_stride_*n) + a_fsas_state_idx01,
                      //    where n is the fsa_idx, i.e. the index into b_fsas_
                      // to
                      // value, where at different stages of PropagateForward(),
                      // value is an arc_idx012 (into cur_frame->arcs), and
                      // then later a state_idx01 into the next frame's `state`
                      // member.

  // The 1st dim is needed because If all the
  // streams share the same FSA in a_fsas_, we need
  // separate maps for each).  This map is used on
  // each frame to compute and store the mapping
  // from active states to the position in the
  // `states` array.  Between frames, all values
  // have -1 in them.
  std::vector<std::unique_ptr<FrameInfo>> frames_;

  // logically an array of bool, of size T_ + 1; for each 0 <= t <= T, after the
  // forward pass finishes propagation with cur_frame_ == t, if
  // do_pruning_after_[t] is false it will continue as normal; otherwise (if
  // true), it will signal `semaphore_`.
  std::vector<char> do_pruning_after_;

  // For each t for which do_pruning_after_[t] is true, there will be a
  // pair (begin_t, end_t) in prune_t_begin_end giving the
  // arguments for which we will invoke PruneTimeRange() after the forward-pass
  // for time t has completed.  The size of this array equals the sum
  // of nonzero elements of do_pruning_after_.
  std::vector<std::pair<int32_t, int32_t> > prune_t_begin_end_;

  // Each time the forward-pass finishes forward processing for a t value for
  // which do_pruning_after_[t] is true, it will signal this semaphore; the
  // backward-pass thread (which does pruning) will wait on it as many times as
  // do_pruning_after_[t] is set to true.
  Semaphore backward_semaphore_;

  // The function of forward_semaphore_ is to ensure that the backward (pruning)
  // pass doesn't "get too far behind" relative to the forward pass, which might
  // cause us to use more memory than expected.  (Note: the backward pass is
  // normally a bit faster than the forward pass, so typically this won't be a
  // problem).  Each time the backward pass has finished one round of pruning it
  // signals this semaphore.  each time after the forward pass signals the
  // backward pass that it's ready to prune, it waits on this semaphore
  // immediately afterward.  But because forward_semaphore_ is initialized to 1
  // rather than zero, the effect is that the forward pass is waiting for the
  // *previous* phase of backward pruning to complete, rather than the current
  // one.
  k2std::counting_semaphore forward_semaphore_;
};

void IntersectDensePruned(FsaVec &a_fsas, DenseFsaVec &b_fsas,
                          float search_beam, float output_beam,
                          int32_t min_active_states, int32_t max_active_states,
                          bool allow_partial,
                          FsaVec *out, Array1<int32_t> *arc_map_a,
                          Array1<int32_t> *arc_map_b) {
  NVTX_RANGE("IntersectDensePruned");
  FsaVec a_vec = FsaToFsaVec(a_fsas);
  bool online_decoding = false;
  MultiGraphDenseIntersectPruned intersector(a_vec, b_fsas.shape.Dim0(),
                                             search_beam, output_beam,
                                             min_active_states,
                                             max_active_states,
                                             allow_partial,
                                             online_decoding);
  intersector.Intersect(&b_fsas);
  intersector.FormatOutput(out, arc_map_a, arc_map_b);
}

OnlineDenseIntersecter::OnlineDenseIntersecter(FsaVec &a_fsas,
    int32_t num_seqs, float search_beam, float output_beam,
    int32_t min_active_states, int32_t max_active_states, bool allow_partial) {
  bool online_decoding = true;
  K2_CHECK_EQ(a_fsas.NumAxes(), 3);
  c_ = a_fsas.Context();
  search_beam_ = search_beam;
  impl_ = new MultiGraphDenseIntersectPruned(a_fsas, num_seqs, search_beam,
      output_beam, min_active_states, max_active_states, allow_partial,
      online_decoding);
}

OnlineDenseIntersecter::~OnlineDenseIntersecter(){
  // WARNING(Wei Kang): Python garbage collector runs in a separate thread,
  // so we have to reset its default device. Otherwise, it will throw later
  // if the main thread is using a different device.
  // Actually, it is the `CheckEmpty` function invoked in Hash's destructor
  // would throw, but I think it is properly to put the DeviceGuard here, as the
  // hanging occurs when destructing this object.
  // Note: The hanging only occurs on the versions built with debug mode, as the
  // release mode won't invoked `CheckEmpty` when destructing Hash objects.
#ifndef NDEBUG
  DeviceGuard guard(c_);
#endif
  delete impl_;
}

void OnlineDenseIntersecter::Decode(DenseFsaVec &b_fsas,
    std::vector<DecodeStateInfo*> *decode_states,
    FsaVec *ofsa, Array1<int32_t> *arc_map_a) {
  int32_t num_seqs = b_fsas.shape.Dim0();

  K2_CHECK_EQ(num_seqs, static_cast<int32_t>(decode_states->size()));

  std::vector<Ragged<StateInfo> *> seq_states_ptr_vec(num_seqs);
  std::vector<Ragged<ArcInfo> *> seq_arcs_ptr_vec(num_seqs);

  Array1<float> beams(GetCpuContext(), num_seqs);
  float *beams_data = beams.Data();
  for (int32_t i = 0; i < num_seqs; ++i) {
    DecodeStateInfo *decode_state_ptr = decode_states->at(i);
    K2_CHECK(decode_state_ptr);
    // initialization; NumAxes == 1 means this is an uninitialized Ragged
    if (decode_state_ptr->states.NumAxes() == 1) {
      StateInfo sinfo;
      // start state of decoding graph
      sinfo.a_fsas_state_idx01 = 0;
      sinfo.forward_loglike = FloatToOrderedInt(0.0);
      decode_state_ptr->states = Ragged<StateInfo>(
          RegularRaggedShape(c_, 1, 1),
          Array1<StateInfo>(c_, std::vector<StateInfo>{sinfo}));

      decode_state_ptr->arcs = Ragged<ArcInfo>(RaggedShape(c_, "[ [ [ x ] ] ]"),
          Array1<ArcInfo>(c_, std::vector<ArcInfo>{ArcInfo()}));

      decode_state_ptr->beam = search_beam_;
    }
    seq_states_ptr_vec[i] = &(decode_state_ptr->states);
    seq_arcs_ptr_vec[i] = &(decode_state_ptr->arcs);
    beams_data[i] = decode_state_ptr->beam;
  }

  auto stack_states = Stack(0, num_seqs, seq_states_ptr_vec.data());
  auto stack_arcs = Stack(0, num_seqs, seq_arcs_ptr_vec.data());

  // Remove empty lists on frame axis, these empty lists come from the
  // Unstack of the previous chunk
  stack_states = Ragged<StateInfo>(RemoveEmptyLists(stack_states.shape, 1),
                                   stack_states.values);
  stack_arcs = Ragged<ArcInfo>(RemoveEmptyLists(stack_arcs.shape, 1),
                               stack_arcs.values);

  std::vector<Ragged<StateInfo>> frame_states_vec;
  std::vector<Ragged<ArcInfo>> frame_arcs_vec;
  // Put empty list left, we want the latest frames at the tail positions
  Unstack(stack_states, 1, false /*pad_right*/, &frame_states_vec);
  Unstack(stack_arcs, 1, false /*pad_right*/, &frame_arcs_vec);

  std::vector<std::unique_ptr<FrameInfo>> frames(frame_states_vec.size());

  for (size_t i = 0; i < frames.size(); ++i) {
    FrameInfo info;
    info.states = frame_states_vec[i];
    info.arcs = frame_arcs_vec[i];
    frames[i] = std::make_unique<FrameInfo>(info);
  }

  const auto new_frames = impl_->OnlineIntersect(
      &b_fsas, frames, beams);

  impl_->FormatOutput(ofsa, arc_map_a, nullptr/*arc_map_b*/);

  int32_t frames_num = new_frames->size();
  std::vector<Ragged<StateInfo> *> frame_states_ptr_vec(frames_num);
  std::vector<Ragged<ArcInfo> *> frame_arcs_ptr_vec(frames_num);
  for (int32_t i = 0; i < frames_num; ++i) {
    frame_states_ptr_vec[i] = &(new_frames->at(i)->states);
    frame_arcs_ptr_vec[i] = &(new_frames->at(i)->arcs);
  }

  stack_states = Stack(0, frames_num, frame_states_ptr_vec.data());
  stack_arcs = Stack(0, frames_num, frame_arcs_ptr_vec.data());

  std::vector<Ragged<StateInfo>> seq_states_vec;
  std::vector<Ragged<ArcInfo>> seq_arcs_vec;
  Unstack(stack_states, 1, &seq_states_vec);
  Unstack(stack_arcs, 1, &seq_arcs_vec);

  beams = impl_->GetBeams().To(GetCpuContext());
  beams_data = beams.Data();
  for (int32_t i = 0; i < num_seqs; ++i) {
    DecodeStateInfo* decode_state_ptr = decode_states->at(i);
    decode_state_ptr->states = seq_states_vec[i];
    decode_state_ptr->arcs = seq_arcs_vec[i];
    decode_state_ptr->beam = beams_data[i];
  }
}

}  // namespace k2
