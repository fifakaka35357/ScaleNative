**English** | [简体中文](FUTURE_WORK.zh-CN.md)

# Future Work

This document lists the work that lies beyond the first public release of ScaleNative
(`v0.2.0`). It has two layers.

- **Near-term** (Section 1): items the authors have decided on, but that are not in
  the RTL yet, or are in the RTL and not verified yet. They are worked through step
  by step. Together they are the gap between the RTL in this repository and the
  target design that the paper describes.
- **Long-term** (Section 2): directions that the current stage of the project will
  not implement, but that a tape-out or a complete hardware-feasibility effort would
  need. Only the direction is named, without structure or numbers.

The Future Work section of the paper covers the long-term layer only. This document
covers both.

A Chinese version of this document is in [FUTURE_WORK.zh-CN.md](FUTURE_WORK.zh-CN.md).
Where the two differ, the English version is the reference.

## How to read this document

- Every entry gives the status today and the next step. No dates are promised.
- The numbers in Section 1 are either design targets chosen by the authors or
  properties of today's RTL. None of them is a measured performance result.
- A *planning point* is a value that the authors plan with before it has been
  implemented or measured. It can change when measurements exist.
- "Not in RTL" means that the RTL in this repository does not implement the item.
- Problems of the released RTL and layouts are listed under "Known limitations" in
  the [README](../README.md). This document says what is planned and does not repeat
  that list.
- Names follow the README: Tensor unit; Vector unit (today) and Vector cores (target
  design); hand-off (the direct path from the Tensor unit to the Vector side, which
  carries blocks of 16 mantissas with one shared exponent); local memory (L2);
  control core (the Ibex core inside a PE); command processor; DMA engine. A *tile*
  is the unit of work of the 16 x 16 Tensor array.
- This repository is an intermediate snapshot. Later releases follow when the RTL
  changes below have landed and when the full test suite passes on them.

## 1. Near-term: decided, not yet implemented or verified

### 1.1 Follow-ups to the first release

| Item | Status today | Next step |
|---|---|---|
| Run the full simulation test suite in this repository's directory layout. | Not run in this layout. The regression run by `run_all.py`, which covers 61 of the 66 test files, passed when it was last run in the private development tree, which is laid out differently. For the release, the path problems found by reading the files were fixed in five files under `tb/` (`Makefile`, `elaborate_smoke.sh`, `test_pe_top.py`, `test_l1i_real_a7.py`, `test_srambank_real.py`; only paths were changed), and the golden model directory was added. | Run every test from a clean checkout, fix what breaks, and update the README. |
| Set up the layout flow from the beginning. | Not done. Only the seven configurations used for the paper's layouts are included; whether this reduced set is self-contained has been checked by reading the files, not by running them. | Follow the build guide on a clean machine and run the seven configurations. |
| Synthesis and timing check for the sum-of-squares correction. | The numerical correction is in the RTL. The synthesis and timing check planned for it has not been run, so its effect on area and timing is not known. The three layout runs that the paper reports predate the correction. | Run the check on the Vector unit before and after the correction. |
| Repeat the layouts on the updated RTL. | One PE top-level run, one Tensor run (first seed) and one Vector run exist. All three are intermediate versions made from the earlier RTL; the PE run still has four routing DRC violations, and none of the three closes timing (README, Known limitations). | After the current round of RTL changes: a PE top-level run, a second run of the same configuration that changes only the routing seed (to measure run-to-run variation), and the remaining Tensor seeds. The layout figure is refreshed after each full run. |
| Logic equivalence check of the layouts. | Not run. | Run it as a separate step with a later full run. |
| Numerical check of the hand-off at PE level. | At PE level the hand-off is verified at handshake level: the tests confirm that blocks leave the Tensor unit and are consumed. The segments of the path are tested separately at unit level. The rows that the Vector unit then writes to local memory have not been read back and compared with the golden model. | Add the read-back comparison to the PE-level test. |
| PE-level tests with the ASAP7 memory macros. | All regression tests use the behavioural memory model. The ASAP7 macro branch is exercised by one test at wrapper level only. | Run the existing PE-level tests, new local-memory cases and a byte-write case for the data memory in the complete ASAP7 configuration, as part of the regression. |
| SRAM macro views. | Open. The LEF and GDS views of the upstream SRAM macro disagree in part of the macro, and the consequence for the layouts has been checked only on a sample. The delay-select pins of the macro are not driven by the design today. | Correct the macro views before the next PE top-level run whose numbers are reported. Drive the delay-select pins from a configuration register that resets to the most conservative setting. |
| Frequency exploration. | The paper makes no frequency claim, and the clock periods in the constraint files are flow settings. The effect of the planned RTL changes on the achievable frequency has not been measured. | Timing work on the updated RTL, including the timing effect of the per-tile overhead levels in Section 1.2. |

### 1.2 Tensor unit

| Item | Status today | Next step |
|---|---|---|
| Stream-in operand loading: one operand stays resident and is double-buffered, and the other streams in row by row from local memory. The descriptor selects which operand stays; the default is the weights. | Not in RTL. Every Tensor command first reloads all of its operands and only then computes. | Write the design for this form (an earlier draft used a different form), then implement. |
| Fixed overhead per tile: the planning point is 5 cycles outside the multiply-accumulate steps. | Not in RTL. Today the tile controller spends a fixed 56 cycles per tile, in addition to the operand reload. The lower levels were derived from timing relations; there is no design or simulation for them, and their effect on the achievable frequency has not been measured. The multicycle exception in the constraint files relies on the load state of today's controller (README, Known limitations). | After stream-in loading: design the controller changes, derive the timing exceptions again, and measure timing before committing. The authors will revisit the planning point when synthesis results exist. |
| Larger 4-bit and 8-bit tiers: planning points of 2048 and 1024 multiply-accumulates per cycle. The BF16 tier stays at 256. | Not in RTL. The array performs 1024, 512 and 256 multiply-accumulates per cycle with FP4, FP8 and BF16 operands (MXINT8 also runs at 256). Which tier 8-bit integer operands will use is not decided. The change needs wider array words and wider rows in the private memory of the Tensor unit, and only one of the two operand sides can then stream in at full rate; its area and timing cost has not been evaluated. | Design, evaluate area and timing, then implement. |
| Accumulators: preload of an initial value, more than one output bank, and continuing a wide-precision partial sum that arrives from another PE. | Not in RTL. An accumulator can only be cleared, and there is one output region. | Design, then implement. How partial sums travel between PEs is settled in the on-chip network design (Section 1.6). |
| MX: GEMM with MX operands at array level, scale loading for K above 32, GEMM results stored in an MX format, and reading such a result back as the input of the next layer in the same PE. | Not in RTL or not verified. MX is verified at cell level only. | Implement and verify these together. |
| MXFP6 in two steps, both required: first the loader expands 6-bit elements exactly to 8 bits and uses the 8-bit path; then a native rate for each format pair, with wider private memory in the Tensor unit. | Not in RTL. | Step one together with the operand loader; step two afterwards. |
| FP16 as a fallback: the loader splits each FP16 value into two BF16 values. No native FP16 multiplier is added. | Not in RTL. | Implement together with the operand loader. |
| Plain INT8 at three levels: acceptance of the format with power-of-2 scales; scales that are not powers of 2; an exact INT32 output. | Not in RTL. The INT8 element code is rejected today. | Design, then implement. The level with scales that are not powers of 2 depends on the form of the Vector cores. |
| A block scale in E4M3 that reaches the array, as in NVFP4. | Not in RTL. The array always uses power-of-2 (E8M0) scales. | A software ablation first, then the hardware change. |
| Mixed-format multiplication: any pair within the MX floating-point family, and non-MX FP8 by FP4. | Not in RTL. A tile has one format for both operands. | Design, then implement. |
| Rounding at the Tensor output: round-to-nearest-even becomes the default; truncation remains an explicit option. | Not in RTL. | Implement, and update the expected values that the change invalidates. |
| N:M sparsity: per-cell operand selection in the array. | Not in RTL. Sparse descriptors are accepted although the selection path does not exist (see Known limitations). | First reject such descriptors (Section 1.5), then build the selection path. |

### 1.3 Vector cores

Two Vector cores per PE are part of the target design in the paper, not a future
idea. What is listed here is the design choice that is still open and the RTL that
remains to be written.

| Item | Status today | Next step |
|---|---|---|
| Two Vector cores per PE (target design). Each of the two drain ports of the Tensor unit feeds one core. The PE keeps all functions when one core is masked, so that a single-core PE can be derived from the same design. Two forms are still candidates: a pipeline core plus a general core, or two identical cores. | Not in RTL. The PE has one Vector unit with 16 lanes. The form is not chosen, and neither candidate has a cycle-level model or an area estimate on the paper's workload yet. | Model the two forms, choose, then write the RTL. |
| Operations that the workload needs and the Vector unit lacks: exponential, general multiplication and top-k selection. | Not in RTL. | Assign them to the two cores in the model round above. |
| Index-score post-processing and top-k selection in a Vector core: a new command (take the positive part, multiply by a per-head weight, merge 16 values into 1, accumulate across head groups), per-lane coefficients, a threshold filter with a candidate table, and an index output. The Tensor output and the hand-off do not change. This is not claimed as a contribution. | Not in RTL. Which core hosts it is open. The core has to take one row per cycle, which the Vector unit does not do today. Area and timing have not been evaluated. | Choose the core in the model round, which also has to show that the core keeps up with index scoring; then implement. |
| Vector width as a parameter. | The default width is not fixed. The rule is that the Vector side must not become the bottleneck of the system. Earlier sizing has to be redone for the larger 4-bit tier. | Fix the default after the model round. |
| Provision for two PE types in a mesh of identical PEs: capability bits in the idle report of a PE and in the task descriptor; whether a PE has the second Vector core becomes a generation-time parameter. | Not in RTL. | Add with the dispatch design (Sections 1.5 and 1.6). |

### 1.4 Hand-off and result storage

| Item | Status today | Next step |
|---|---|---|
| Block identity: context and tag filled in, plus a row index and a last-row marker (a new revision of the block format). | Not in RTL. Context and tag are tied to 0. | Implement. |
| Publication of results: inside an output transaction, rows can be consumed as they arrive; outside it, the result becomes visible only when all rows and metadata are complete and no error occurred. One output transaction of a GEMM is consumed as a whole by exactly one consuming command. | Not in RTL. | Design, then implement. |
| Storing a block result together with its exponent: mantissas plus an exponent side record whose rows are shared by several objects and updated by read-modify-write, so that a stored result can be read back and consumed again. | Not in RTL. The ordinary store writes mantissas only. | Write the new design version, then implement. |
| Rows that cannot be represented with one shared exponent: a hint selects between raising an error, consuming and counting (the default), and consuming while keeping a high-precision copy. NaN and infinity still end in an error. | Not in RTL. Such rows are dropped at the entry of the hand-off FIFO. | Implement the rule. The high-precision copy is a separate step with its own acceptance checks, and falls back to counting only if it fails them. |
| Placement of the output accumulator of attention, compared by model over four placements: moved over the hand-off into memory local to a Vector core; read by a Vector core directly from the Tensor output region; kept in the Tensor unit, which continues to accumulate and applies a coefficient per row; and a two-pass method. Online softmax and top-k are allowed to differ from the reference software kernels, and each difference will be stated in the paper. | No model results yet. Memory local to the Vector core is the working default. | Run the comparison, report the share of traffic that still uses the hand-off, then choose. |
| The hand-off with two Vector cores; circular buffers on the hand-off and on regions of local memory. | Not in RTL. One FIFO connects the Tensor unit to the one Vector unit. | Follows the choice of the Vector core form. |
| Errors on the hand-off: a block that does not match what the Vector side expects ends in an error of the right type at the command processor. | Not in RTL. See Known limitations for today's behaviour. | Connect the error outputs of the Vector unit to the command processor and correct the error classification. |

### 1.5 PE control, memory and errors

| Item | Status today | Next step |
|---|---|---|
| Local memory contract for single-port macros: mutual exclusion per bank, grant and read-valid only for requests that are actually served, a starvation quota, and the same contract in the behavioural model and in the ASAP7 branch. | Not in RTL. The two branches behave differently (see Known limitations). | Write the new design version, implement it in both branches, and fix the same-cycle priority order by measurement. |
| Memory sizes of the target design: local memory (L2) of 128 KiB per PE, reached by first pairing adjacent banks to use the full 64-bit width of the macros; instruction memory of 4 KiB; data memory of 8 KiB. | Not in RTL. Today the sizes are 32 KiB, 2 KiB and 4 KiB, which are also the sizes in the layouts. The macro arrangement for 128 KiB is not chosen. | After the current round of RTL changes. 128 KiB is a starting point; capacity is then swept by model (Section 1.7). |
| Access of the control core to the memories: a window into local memory with lowest priority and bounded waiting; byte, half-word and word writes executed atomically by a read-modify-write unit at the bank; the data port may write the instruction memory. | Not in RTL. Local memory is not in the address space of the control core. | Design with the local memory contract, then implement. |
| Descriptors and dispatch: variable-length descriptors (a long descriptor takes two adjacent slots); persistent context slots with auto-incrementing offsets; a job ring from which the PE pulls work-queue entries; wait primitives across PEs (signal and wait-for-dependency) with a scoreboard. | Not in RTL. | Design, then implement. The job-ring interface is settled in the on-chip network design (Section 1.6). |
| Reset and cancellation under load: soft reset while busy, explicit cancellation of one context, an abort of the Tensor unit alone, and defined behaviour for interrupted DMA transfers and for paired commands. | Not in RTL in this form. | Implement the agreed rules with their tests. |
| Interrupt controller and machine timer. | Not in RTL. | Design, then implement. |
| DMA: several transfers in flight (four by default), merging of reads, and multicast of responses and of writes. | Not in RTL. | Derive the number of transfers from the bandwidth requirement; implement with the shared-memory node of Section 1.6. |
| Acceptance and errors: reject illegal commands and descriptors that ask for unimplemented sparse modes, with one capability table shared by the command processor and the register layer; deliver execution errors to the command processor; no silent overflow; safe clock gating. | Partly in RTL. Permanently illegal encodings are already rejected when a descriptor is fetched. The rest is open (see Known limitations). | The rejection of unimplemented sparse modes comes first, then the error path. |
| The sum-of-squares unit reachable by a command. | Partly in RTL. The datapath with its numerical correction is in, but no command uses it. | Connect the command path, together with the timing check of Section 1.1. |

### 1.6 Mesh level (design in progress)

The authors decided to build the mesh-level RTL now rather than leave it for later.
Its design documents are still being revised, so the details in this section may
change. None of it is in the RTL.

| Item | Status today | Next step |
|---|---|---|
| On-chip network: a router, the endpoint on the PE side, a testbench of 2 x 2 PEs, and a bridge between the network and AXI. | Not in RTL. | Finish the design, then implement on the 2 x 2 testbench. |
| Local port of a PE with a payload of 64 bytes per cycle (planning point). | Not in RTL. The PE has 32-bit ingress and egress stream ports. The wire count and the router area of the wider port have not been evaluated. | With the network endpoint. |
| Loading and management over the network: the boot pins are removed, each PE has a reset register, and the memories of a PE are mapped so that the level above can read and write them. | Not in RTL. A PE is loaded through a separate boot port. | With the network endpoint. |
| One on-chip Control Core for the mesh. CVA6 is used as the verification case, and the core sits in a socket so that it can be replaced. Its firmware also masks faulty PEs. | Not in RTL. | Finish the design with the network, then integrate on the testbench. |
| Host entry: a control plane and an address window that passes through to the mesh; the submission queue in device memory by default, with host memory as a fallback; no separate management processor. The Control Core, the host interface and the shared memory are each a node of the network. | Not in RTL. | Finish the design with the network. |
| Shared memory at the edge of the mesh (L3), managed by software as a buffer. The planning range is 128 to 256 MiB for one 8 x 8 mesh; a whole layer stays resident by sharing it across dies, and data are prefetched layer by layer. | Not in RTL. The capacity and the bandwidth into the mesh are still being derived from the workload. In RTL the node will have a small capacity for the testbench; conclusions for large capacities come from system-level modelling. | Fix capacity and bandwidth in the design revision, then implement the node on the 2 x 2 testbench. |

### 1.7 Workload and evaluation

| Item | Status today | Next step |
|---|---|---|
| The hand-off arrangements compared in the paper, built from the same RTL: block-scaled or scalar, direct or through local memory, and fusion at the producer. | Only the block-scaled direct hand-off is in RTL. The scalar direct variant and the write side of the block-through-memory variant are not implemented. Whether the scalar-through-memory variant gets RTL or a model is not decided. Fusion at the producer is evaluated outside the PE RTL. | Build the variants as their prerequisites in Section 1.4 land. |
| Precision of the attention core: the query is quantized to 8 bits so that the core runs in the 8-bit tier. | Chosen as the design point of the target design; nothing in the RTL implements it. It adds two quantization steps compared with the reference implementation, and there is no data on the effect on model quality. The newer generation of the workload stores its main key-value data in 4 bits, which also needs a lossless conversion to 8 bits. | Evaluation on the model side, which this repository cannot provide; design the conversion path. |
| System-level evaluation by modelling: calibrated on one PE, then projected to a mesh. Results at this level are marked as modelled. | There is no system model in this repository, and the source of the paper's performance data is not decided. | Decide the modelling route, calibrate on the single-PE RTL, then project. |
| Memory capacity sweep: with local memory fixed at 128 KiB first, sweep capacity by model and report BF16, MXFP8 and MXFP4 side by side. Conclusions on the shared memory come from the system model. | Not started. | After the system model exists. |

## 2. Long-term directions

| Direction | Why it is listed | Status today | Next step |
|---|---|---|---|
| 3D stacking and a 3D mesh. | The mesh in this work is two-dimensional, and the paper does not use 3D integration. The third dimension is planned as follow-on work. | Direction only. | Not scheduled. It follows the two-dimensional mesh. |
| Heterogeneous PE mesh: PEs of different types in one mesh. A PE that has both a Tensor unit and Vector cores is the usual arrangement and is not what "heterogeneous" means here. | At system level, attention and feed-forward work are mapped onto the mesh at the same time, and they need different amounts of vector compute relative to matrix compute. | Not designed. The mesh in this work uses identical PEs and only makes provision for a second type (Section 1.3). Whether two PE types are worth the mapping constraint they bring is not established. | Study the trade-off, together with task mappings that would use it. |
| Error correction (ECC) for the memories. | The memories have no error detection or correction. Few ASAP7 SRAM macros are available to an open-source flow and none of them supports ECC. Its absence does not affect the simulations of this work. | Not implemented. | Reconsider when macros with room for check bits are available, or when the process changes. |
| Debug module. | No tape-out is planned on ASAP7, and simulation does not need one. | No debug module is attached to the control core. | Add it if a tape-out is planned. |
| A stronger Control Core, and several Control Core domains. | At this stage the on-chip Control Core is one open-source core used as a verification case, in a replaceable socket. A mesh larger than one Control Core can manage would be divided into domains with one Control Core each. | Direction only. The first Control Core itself is near-term (Section 1.6). | Replace the core with an out-of-order open-source core through the same socket; study the size of a domain. |

## 3. What is not listed

Topics that have been discussed but not decided by the authors are not listed here.
They will be added when they are decided.
