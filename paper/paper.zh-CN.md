[English (LaTeX sources: sections/)](sections/) | **简体中文**

> 本文件是英文 LaTeX 稿（`sections/*.tex`）的逐段中文对照，供把关用，不是发表稿；两者有出入时以英文稿为准。
> 每段开头的 `<!-- P:编号 -->` 与英文稿里的 `%% P:编号` 一一对应，编号定下后不重排、不复用。
> 写法约定：占位写成 `[TBD-编号: 等什么]`；文献写成 `[@键]`；待补的文献写成 `[ref: 英文名]`；
> 图、表、节的引用写成 `[图 5](#fig:pe)` 这样带锚点的链接；数字、单位与型号照英文稿原样写阿拉伯数字，
> 英文拼成单词的数（three）在这里写汉字（三）。改完后跑 `python3 check_align.py`。
> 现在是第一版完整正文：每段、每条图注表注都已写成；结果处是占位。六张图已经放入（图 4 到图 8 与图 13，文件在 `figures/`），七张表都已经排出（英文表体在 `tables/`；表 2 有两格是占位）；其余 8 个图位还是空框。
> 排好的表在本稿里这样写：表注一段在前，表脚接在同一段里、写在「表脚：」之后；空一行之后是数字相同的 Markdown 表，表后不再跟文字。英文表里跨栏的格，这里只在第一格写内容，被它盖住的格留空或写「同左」。
> 各图表位写的「要画 / 要列」与「现状」是给作者看的说明，不是图注。已经放入的图把「要画」改写成「画的是」，逐句对应英文稿里这张图的替代文字（acmart 的 `\Description`）。
> 英文稿里的 L2（术语宏 `\Lii`，PE 内的本地存储）在本稿正文里一律写「PE 本地存储」：对齐检查器按字面比数字、不展开术语宏。图注与图位说明里指图上标注的地方照图写 L1、L2、L3，英文稿在这些地方写的也是字面的名字。Prototype / Corrected / Projected 是英文稿里三个配置的暂用名，依次指今天的 RTL、修正后的 PE、投影的系统。

# 标题（暂定）：Keeping GEMM Results Block-Scaled across the Tensor–Vector Hand-off: When Does It Pay Off?

## 摘要

<!-- P:abs-p1 -->
GEMM 的结果可以在生产端的融合 epilogue 里就地消费，也可以形成标量或块缩放表示，再交给独立的向量单元。这个选择改变三件事：舍入发生在哪里、执行资源被占用多久、中间结果存多少与以什么形式存。本文研究让结果以块缩放形式跨过这道矩阵到向量的交接何时划算；研究对象是一个处理单元（PE），由一个脉动阵列式的 Tensor 单元与两个 Vector 核组成 [TBD-D1: 两个 Vector 核的形态、宽度与分工]。我们比较交接的五种方式：至多四种是同一份 RTL 上的编译期配置，融合的那一种用综合切片加校准过的周期模型；数值误差在合成输入上评估。我们用融合是否可行、结果寿命、元数据事务粒度来刻画何时划算 [TBD-E4: 块表示在哪些区间划算、哪些不划算]，并报告失败可见的交接要付出的代价 [TBD-E8: 实现代价] 与系统级投影 [TBD-P: 系统级结果；性能数据的来源]。同一公开模型系列前后两代的三个模型（DeepSeek-V4-Pro 与 V4-Flash，以及其后的 V4.1-Flash）的解码既是设计的动机，也是评估负载。今天的 RTL 原型只有一个 Vector 核，只实现了其中一种交接方式；物理结果是 ASAP7 预测型 PDK 上的布线后 EDA 估计，不是硅测量。

## 1 引言（Introduction） <a id="sec:intro"></a>

<!-- P:sec1-p1 -->
通用矩阵乘（GEMM）的结果可以在生产端就地消费——在与矩阵引擎融合在一起的 epilogue 里；也可以形成标量或块缩放表示，再交给独立的单元。这个选择改变数值在哪里舍入、执行资源被占用多久、存放中间结果要付出多少。本文研究这几样合在一起，怎样决定块表示何时值得保留。

<!-- P:fig1-cap -->
<a id="fig:handoff"></a>**[图 1](#fig:handoff)**（单栏）要画：五种交接方式并排：结果在哪里形成表示、是否经过存储、在哪里被消费。现状：概念图，还没画。图注：五种交接方式。块缩放（B）或标量（S）结果直接交接（D）或经存储交接（M）；S-E 则把消费融合进生产端的 epilogue。

<!-- P:sec1-p2 -->
以 GEMM 后接残差加为例（[图 1](#fig:handoff)）。在 B-D（块、直接交接）里，矩阵引擎的出口形成块缩放结果，向量单元在块域里加残差。在 S-D（标量、直接交接）里，出口把每个值转成标量浮点。在 S-E（标量、融合 epilogue）里，生产端在自己的 epilogue 里加完残差，之后才形成输出表示。量化与加法不可交换（一般而言 $Q(A)+R \neq Q(A+R)$），所以尾数位数相同并不等于数值质量相同；要先冻结每种方式的计算与舍入顺序，再比代价。少一次标量转换不保证成本更低；融合虽然省一次搬运，却可能延长累加器的占用，或加重出口端口的负担。

<!-- P:sec1-p3 -->
在本文核查过、且公开资料足以判定交接格式的量产设计里，矩阵引擎交给向量执行的是标量，块格式由专用量化器重建，向量指令集只在格式转换指令里接受 block scale（[§2.2](#sec:bg-today)）。学术设计已经让块格式跨过矩阵算子与非矩阵算子之间的边界 [@Wang2025DBAttn] [ref: MXInt ViT] [ref: MASE]，所以「跨过这道边界」本身不是新东西（[§7](#sec:related)）。还没有回答的是：一个 Tensor 单元与 Vector 核彼此独立、都是被复用的资源，存储与端口都有限的处理单元（PE），该在哪里形成块表示，又该把它保留多久。

<!-- P:sec1-p4 -->
用作动机的负载，是同一公开模型系列前后两代、三个模型的解码：DeepSeek-V4-Pro 与 V4-Flash，以及其后的 V4.1-Flash [@DeepSeekAI2026V4ProHF; @DeepSeekAI2026V41Flash; @DeepSeekAI2026V41FlashHF] [ref: DeepSeek-V4 paper] [ref: DeepSeek-V4-Flash model repository]。从 V4 到 V4.1，模型各部分在解码一步里的占比、存放格式与 scale 块的大小都变了，一组结构量没有变（[§2.4](#sec:bg-workload)）。这些变化是目标设计的动机；三个模型的运算计数由解析推导得到，构成评估负载（[§5.4](#sec:workload-method)）。

<!-- P:sec1-p5 -->
块的 payload 离开它的 scale 就没有意义；如果任何 payload 都不可能在过期或错配的元数据之下被消费而不报错，就称这种交接是失败可见的。我们问一个问题，分两半。在一个由矩阵单元与向量单元组成的 PE 中，把 GEMM 结果以块缩放格式跨过矩阵到向量的交接——直接前传，或连同 scale 提交后再消费——相对标量浮点交接与融合 epilogue，在等数值质量下何时划算？让这种交接失败可见、并在派发时或在数据通路上核对 scale 元数据，各要付出什么？ [TBD-N: 定稿措辞；研究问题里要不要带上事务粒度]

<!-- P:sec1-p6 -->
我们把不同形式的证据分开。至多四种交接方式是同一份 RTL 上的编译期配置，用 RTL 仿真比较。生产端融合不在 PE 的 RTL 里；我们用综合切片加周期模型评估它，同时报乐观界与校准估计。数值误差在合成输入上评估，用的是一个按硬件的累加与舍入顺序计算的模型。系统级影响是模型投影 [TBD-P: 周期级与系统级性能数据的来源]。正文按目标设计写；[§4](#sec:uarch) 的每个小节末尾交代今天的 RTL 原型实现到哪一步。今天做到的是一种交接方式（B-D）；负载刻画与一张布线后版图已有，各交接方式之间还没有做过比较。

<!-- P:sec1-p7 -->
本文有两条贡献。（1）一条发现：保留块表示跨过矩阵到向量的交接何时划算，用融合是否可行、结果要保留多久、元数据事务的粒度这三样来刻画 [TBD-E4: 划算区间的边界；今天还没有实验结果]。（2）一条工程机制：失败可见的块结果交接与提交协议——失配与错误上报 PE 的命令处理器，结果的 payload 与 scale 元数据齐全之后才发布；快通道（从 Tensor 单元直通 Vector 核的链路）在这一条里。RTL、它的逐位参考模型（金标）与评估用的模型是证据平台，不单列为贡献。

## 2 背景与动机（Background and Motivation） <a id="sec:background"></a>

### 2.1 块缩放格式与三条块轴（Block-Scaled Formats and Three Block Axes） <a id="sec:bg-formats"></a>

<!-- P:sec2.1-p1 -->
块缩放格式让 $k$ 个元素 $P_i$ 共享一个 scale $X$，元素 $i$ 表示 $X \cdot P_i$ [@OCP2023MXSpec]。本文用这个词统称三类：块浮点（BFP），整数尾数共享一个指数，块大小因设计而异 [@Fowers2018Brainwave; @Drumond2018HBFP; @DarvishRouhani2020MSFP]；OCP MX，$k=32$，scale 为 E8M0 [@OCP2023MXSpec; @DarvishRouhani2023MXFormats]；NVFP4，元素为 E2M1，每 16 个元素一个 E4M3 scale，每个张量另有一个 FP32 scale [@NVIDIA2025NVFP4Blog]。

<!-- P:sec2.1-p2 -->
全文把三条块轴分开说；下面的数值是原型的。输入 scale 块沿内积维 $K$：在 MAC 单元的 MX 输入模式下，32 个元素共享一个 E8M0 scale。输出块沿输出维 $N$：一个输出行的 16 个元素共享一个二的幂指数。存储组是 scale sidecar 的一行；sidecar 把块指数与 payload 分开存放，每行 16 个。所以 GEMM 出口是在形成新的块表示，不让输入 scale 原样穿过 [TBD-D7: 三条块轴在目标设计下的写法]。

### 2.2 今天的交接在哪里做（Where the Hand-off Happens Today） <a id="sec:bg-today"></a>

<!-- P:sec2.2-p1 -->
下面盘点本文核查过、且公开资料足以判定交接格式的设计。NVIDIA Blackwell 上，块缩放乘积以 FP32 累加，cuBLAS 在 GEMM 末尾量化 [@NVIDIA2026PTXISA94; @nvidia_cublas_13_4]。MTIA 2i 把 FP32 结果直接前传给浮点 SIMD 引擎 [@Coburn2025MTIA2]。Tenstorrent 存放 BFP；它默认的逐元素通路在计算前解包成 FP32 或 BF16，写回时再打包 [@tenstorrent_isa_wormhole; @tenstorrent_metalium_dataflow]。Trainium3 与 Maia 200 输出标量；块格式在下游重建 [ref: Trainium3; Maia 200]。在矩阵乘指令之外，Intel AMX、PTX 与 CDNA 4 只在格式转换指令里接受 block scale [@NVIDIA2026PTXISA94; @amd2025cdna4] [ref: Intel AMX]。

<!-- P:sec2.2-p2 -->
本文不主张这些设计不能保留块表示，也不以「它们是专用设计」为由排除前作；本文问的是交接位置的选择在什么条件下改变代价与数值。盘点到的做法里有两样是强基线：GEMM 末尾的融合量化是 S-E 在量产设计里的对应，矩阵到向量的直接前传也是成熟做法，所以 B-D 与它的差别只在前传的格式。公开资料没有披露的，不当作不存在。

### 2.3 两条待检验的命题（Two Hypotheses to Test） <a id="sec:bg-hypotheses"></a>

<!-- P:sec2.3-p1 -->
我们提出两条命题，它们是待检验的假设，不是结论。命题 A：融合位置、结果寿命与数值收窄的时点共同决定块表示交接是否划算。对局部、单消费者的操作，生产端融合在某些资源条件下占优；而当结果需要保留、被重复消费，或要等跨块的信息时，保留块表示可能有一个可预测的优势区间。命题 B：元数据事务的粒度可能决定块表示驻留是得还是失，哪怕数值表示不变。两条分别检验，再在 [§6.3](#sec:res-payoff) 综合；综合时每种交接方式的收窄点各自固定（[§3.1](#sec:placements)）。

### 2.4 负载的演进与它提出的设计问题（A Workload in Motion and the Design Questions It Raises） <a id="sec:bg-workload"></a>

<!-- P:fig2-cap -->
<a id="fig:workload"></a>**[图 2](#fig:workload)**（单栏）要画：三个模型里模型各部分的乘加占比随上下文长度的变化。现状：有素材图，要按单栏重排。图注：解码每个 token 的乘加运算按模型各部分的占比，随上下文长度的变化（解析推导）。V4.1-Flash 在 64K 及以上按它的报告的口径。

<!-- P:tab1-cap -->
<a id="tab:workload-gen"></a>**[表 1](#tab:workload-gen)**（单栏）表注：前后两代、三个模型解码一步的需求；各项是解析计数，不是测量。V4.1-Flash 在 1M 一档按它的报告的口径；读缓存的字节数计入块的 scale。

| 解码每个 token | V4-Pro | V4-Flash | V4.1-Flash |
|---|---:|---:|---:|
| 层数 / 隐藏维 | 61 / 7,168 | 43 / 4,096 | 40 / 5,120 |
| 上下文 8K 时的乘加数（$10^{10}$） | 5.466 | 1.477 | 1.796 |
| 上下文 1M 时的乘加数（$10^{10}$） | 15.16 | 7.017 | 2.875 |
| 8K 时最大的一部分：前馈专家（%） | 51.6 | 51.3 | 55.2 |
| 1M 时最大的一部分：索引打分（%） | 42.5 | 64.3 | 38.3 |
| 1M 时读缓存的字节数（MB） | 705.3 | 479.3 | 183.3 |
| 主 KV 条目，512 维 | 448 维 8 bit + 64 维 BF16 | 同左 | 512 维 4 bit |
| 8 bit 的块：权重 / 激活 | 128×128 / 128 | 同左 | 32×32 / 32 |
| 三个模型都一样：索引打分每 128 次乘加对应一次带 ReLU 的加权求和； | | | |
| 注意力核心每 128 次乘加对应一次 softmax 累加器的重标定。 | | | |

<!-- P:sec2.4-p1 -->
这三个模型的上下文上限都是一百万 token。我们按它们的公开配置与参考实现，解析推导解码每个 token 的乘加运算（MAC）数（[§5.4](#sec:workload-method)），并按模型的部分归类：索引打分（索引器与缓存的键做 128 维内积，据此选出分数最高的 $k$ 条）、注意力核心（对参与注意力的条目打分，并在在线 softmax 下加权求和）与前馈专家。运算构成随上下文变化（[图 2](#fig:workload)、[表 1](#tab:workload-gen)）：上下文 8K token 时，前馈专家占全部乘加的 51.3%–55.2%；1M 时最大的一部分是索引打分，占 38.3%–64.3%（V4.1-Flash 按它的技术报告的口径，[§5.4](#sec:workload-method)）。

<!-- P:sec2.4-p2 -->
三个模型之间有一组结构量没有变：头维 512、索引维 128、在线 softmax 每 64 条一组。变了的是各类运算的占比、存放格式与 scale 块的大小：V4.1-Flash 把主 KV 条目改成 4 bit 存放，并把 8 bit 的块从 128 缩到 32。它的作者说，这种格式是为了省存储，不是为了加速矩阵乘 [@DeepSeekAI2026V41Flash]；V4 的作者则提议把 SwiGLU 换成不含指数与除法的逐元素激活，免得矩阵乘之后的处理卡住矩阵乘流水线 [ref: DeepSeek-V4 paper]。

<!-- P:sec2.4-p3 -->
由此引出六个设计问题；目标设计的回答都是规划点，原型有什么见 [§4](#sec:uarch)。（i）矩阵乘之外的运算由哪个单元做：每个 PE 两个 Vector 核，形态未定（[§4.4](#sec:consumer)）。（ii）用一型 PE 还是两型：一型，并为第二型预留能力位。（iii）各位宽档的算力：4 bit、8 bit 与 BF16 三档，每个 PE 每拍分别 2048、1024、256 次乘加。（iv）块缩放的交接能省什么：这正是本文的问题。（v）共享存储与 PE 的本地口：每张 8×8 Mesh 配 128–256 MiB 共享存储，进每个 PE 的本地口每拍 64 字节有效载荷（[§4.1](#sec:pe-org)）。（vi）每个 tile（阵列的一趟运算）的固定开销：5 拍。

## 3 让结果保持块缩放：设计空间、表示与协议（Keeping Results Block-Scaled: Design Space, Representation and Protocol） <a id="sec:design"></a>

<!-- P:tab2-cap -->
<a id="tab:placements"></a>**[表 2](#tab:placements)**（通栏）表注：五种交接方式。B / S：块表示或标量表示；D / M / E：直接交接、经存储，或融合的 epilogue。表脚：acc.：对完整 $K$ 的累加。本表按目标设计写，块大小与各处位宽取原型的值（[§2.1](#sec:bg-formats)）；原型里只有 B-D（[§4.6](#sec:one-rtl)）。

| | 表示 | 是否经存储 | 数值顺序；N1、N2：收窄点 | 消费端与资源 | 证据 |
|---|---|---|---|---|---|
| B-D | 每个输出行一个块：16 个 16 位的尾数，共享一个二的幂指数 | 否：经 FIFO，再过入口核对 | acc. → N1：形成块，48 位收窄到 16 位，取行内最大指数 → 在块域里加残差 → N2 → 写回 | 16 条通道，尾数 16 位，每块一个指数 [TBD-D1: 用一个核还是两个核] | RTL 仿真 |
| S-D | 标量 BF16 或 FP32，分成两组 | 否 | acc. → N1：出口转成 BF16 或 FP32 → 在标量域里加残差 → 写回 | 标量通道；出口转换器取代块形成 | RTL 仿真 |
| S-E | 生产端内部是 FP32；过了 epilogue 才形成输出表示 | 否；残差从 PE 本地存储读入 | acc. → 在 epilogue 里按 FP32 加残差 → N1：形成输出表示 | FP32 的 epilogue；可以暂存 16 个值或重放 | 综合切片、周期模型 |
| B-M | 块：payload 加 scale sidecar | 是：写入、读回、再消费 | 到写回为止同 B-D；存储环节不再收窄；读回后在块域里消费 | 同 B-D；scale sidecar 的更新是读改写 | RTL 仿真 |
| S-M | 真实的 BF16 或 FP32 编码 | 是 | acc. → N1：转成 BF16 或 FP32 → 写入 → 读回 → 标量消费 | 同 S-D；写入时编码、读回时解码 | 未定 [TBD-E4: 用 RTL 还是用模型] |

### 3.1 五种交接方式（Five Hand-off Placements） <a id="sec:placements"></a>

<!-- P:sec3.1-p1 -->
[表 2](#tab:placements) 定义了交接的五种方式。B-D 与 S-D 把每个输出行直接交给 Vector 一侧，前者作为一个块，后者作为标量；S-E 在生产端的 epilogue 里把结果消费掉；B-M 与 S-M 先把结果写进 PE 本地存储，读回之后再消费 [TBD-D1: 五种方式在一个 Vector 核上比还是两核都算]。<!-- 译注：英文稿这里用术语宏 \Lii（印出来是 L2）。check_align.py 不展开术语宏，中文若写 L2 会多数出一个 2，所以正文里凡 \Lii 处都写「PE 本地存储」。 -->

<!-- P:sec3.1-p2 -->
五种方式共用四条约束；只有在这些约束之下、并且守同一个误差预算，才说一种方式比另一种划算 [TBD-N: 判定用的指标与误差预算，在扫描前定死]。主比较固定物理位宽与总字节预算，其中 PE 本地存储取目标容量 128 KiB（原型是 32 KiB）；辅助比较固定能放下的块数。各方式的调度互相匹配，调度带来的收益不记到表示头上。进入下一个 GEMM 之前的转换，计给每一条需要它的路径。累加精度、残差注入次数、收窄点、归约顺序与舍入方式，都在做任何性能比较之前冻结；目标设计的出口缺省按就近偶数舍入 [TBD-D7: 各收窄点的舍入方式，合入后按 RTL 现读]。

### 3.2 每组对照能归因什么（What Each Comparison Can Attribute） <a id="sec:attribution"></a>

<!-- P:tab3-cap -->
<a id="tab:attribution"></a>**[表 3](#tab:attribution)**（单栏）表注：归因矩阵：每组两两对照隔离出什么，以及它必须先确立、不能默认成立的条件。

| 对照 | 隔离出 | 必须先确立的条件 |
|---|---|---|
| B-D / S-D | 表示 | 可用资源、数值契约与处理能力相同 |
| B-M / S-M | 表示 | 往返完整、保护语义相同、按真实格式编码 |
| B-D / B-M | 物化到存储 | 两边都能完成同一工作量 |
| S-D / S-M | 物化到存储 | BF16 与 FP32 分别成组 |
| S-D / S-E | 融合位置 | 累加精度、舍入点、消费精度与最终量化一致 |
| B-D / S-E | 两种完整设计 | 既不单独隔离转换，也不单独隔离融合 |

<!-- P:sec3.2-p1 -->
两两对照各隔离出一个因素：表示、物化到存储或融合位置，每组都有一个必须先确立的条件；B-D 对 S-E 比的是两种完整设计（[表 3](#tab:attribution)）。B-D、S-D、B-M、S-M 四种都有同一种证据时，按成本 $C$ 计的交互项是 $I=(C_{B,M}-C_{S,M})-(C_{B,D}-C_{S,D})$；出自不同证据形式的成本不相减。

### 3.3 消费者档次（Consumer Tiers） <a id="sec:tiers"></a>

<!-- P:sec3.3-p1 -->
我们定义三档消费者。第一档是残差加。第二档是按块的平方和。第三档像归一化那样，先算一个统计量，再把原结果消费一遍：设 $X$ 是在完整的 $K$ 上累加出的 GEMM 输出，$s_r=\sum_{j\in\mathcal{J}_r}X_{rj}^2$，$Y_{rj}=X_{rj}\,h(s_r)$，其中 $h$ 是一个标量函数，$\mathcal{J}_r$ 是一个 16 元素的块，或跨至少两个输出块的一行 [TBD-E4: 第三档做不做评估、做哪几个规模]。$X$ 的表示与 $h$ 的成本事先定死；$h$ 若由主机或模型来算，每种交接方式付同样的成本。融合基线可以把这 16 个值缓冲起来，或者重放；任何一种方式都不能免费保留结果。

### 3.4 结果保留与发布（Retaining and Publishing a Result） <a id="sec:retain"></a>

<!-- P:fig3-cap -->
<a id="fig:retain"></a>**[图 3](#fig:retain)**（单栏）要画：结果保留与发布路径，协议并作一个面板。现状：只有草图。图注：一个结果的保留与发布路径（目标设计），其中三个事件是分开的。原型实现到 payload 写回为止。

<!-- P:sec3.4-p1 -->
一个输出事务（生产端输出的各行连同它们的元数据），要等它的全部行与元数据都完成、并且没有粘滞错误，才发布，也就是对事务之外的消费者可见。绑定在这个事务上的生产端到消费端的链可以随到随消费各行，但它写出的对象保持未发布；晚到的错误归属原事务，并阻止发布。snapshot 的复用、credit 的归还与事务的退休是三个分开的事件（[图 3](#fig:retain)） [TBD-D7: 写出对象的布局，等写回设计稿]。

<!-- P:sec3.4-p2 -->
有一条约束决定了这条路径的样子：PE 的命令处理器在 GEMM 完成时就释放 context（它的一路命令队列），早于它的输出排空。按我们对 RTL 的分析（没有仿真过），如果把释放推迟到输出退休，在同一个 context 里交替下发生产命令与消费命令的链会死锁：消费命令派发不出去，交接 FIFO 填满，出口停住，GEMM 永远报不了完成。所以资源提前释放，同时必须留下一份比资源活得更久的完成记录，用来了结仍在途中的行。

### 3.5 对象、生命周期与在途身份（Objects, Lifetime and In-flight Identity） <a id="sec:objects"></a>

<!-- P:sec3.5-p1 -->
目标设计的协议跟踪三类信息。对象的数值编码（scale、codec、分组与有效范围）随对象一起存放，不由消费者的期望值重新拼出。对象的生命周期（哪一版可见、谁持有读租约、谁可以写）记在命令处理器里一张有限的对象表中。在途结果的身份随每个 capsule（一个输出行连同它的元数据）一起走：context、tag、行号与末行标记 [TBD-D7: 编码信息存在哪里、租约何时结束]。

### 3.6 元数据事务模型（Metadata Transaction Model） <a id="sec:metadata"></a>

<!-- P:sec3.6-p1 -->
命题 B（[§2.3](#sec:bg-hypotheses)）用一份事务账来检验。设一次 scale sidecar 的物理访问是 $w$ 位，每块 $k$ 个元素，一次合并更新覆盖 $g$ 个块，则一次读改写的成本是每元素 $C_{\mathrm{RMW}}=2w/(kg)$ 位；$g$ 受缓冲容量、到达顺序与提交时机的限制。SRAM 宏没有字节掩码，所以每一次部分更新都是一次读改写，还可能与读请求相撞。这份账另有五项（payload 访问、尾块与掩码、对象表访问、等待合并、冲突停顿），对 B-M 与 S-M 用同一条从生产到消费的边界。普通的写合并是强基线 [TBD-D7: scale 元数据的存放布局，等写回设计稿]。

## 4 微架构（Microarchitecture） <a id="sec:uarch"></a>

### 4.1 PE 组织与评估边界（PE Organization and Evaluation Boundary） <a id="sec:pe-org"></a>

<!-- P:fig4-cap -->
<a id="fig:system"></a>**[图 4](#fig:system)**（单栏）画的是：目标系统的框图。片外的 Host 接到 Host interface。SoC 框里，Host interface、Control Core 与 128–256 MiB 的 L3 排在一张同型 PE 的 Mesh 上方，Mesh 标着 8 × 8 PE mesh；图上画了其中十五格和一个省略号，相邻的格之间是双向短线，上面三块各自接到 Mesh 的上边。其中一个 PE 就地放大：上面是 Ibex CPU、L1、DMA 与命令处理器，中间是 Tensor 单元经一条粗箭头接到 2 个核的 Vector 单元，下面是 128 KiB 的 L2，左边框上有一个朝里的端口，标着 64 B/cycle。现状：已画，文件 `figures/fig-system.pdf`。图注：目标设计的系统组织：一张同型 PE 的 Mesh（相邻 PE 之间的链路就是片上网络），加 host 接口、Control Core 和共享的 L3。其中一个 PE 就地放大；粗箭头是 Tensor 到 Vector 的交接。今天的原型 RTL 是一个 PE，只有一个 Vector 核，L2 是 32 KiB；PE 以上的部分都没有实现。

<!-- P:fig5-cap -->
<a id="fig:pe"></a>**[图 5](#fig:pe)**（通栏）画的是：目标设计里一个 PE 的框图。左边是控制一列：命令处理器、Ibex CPU、L1（内有 8 KiB 的 L1D 与 4 KiB 的 L1I）、DMA 与 NoC endpoint；PE 的外框上有一个朝里的端口（标着 64 B/cycle）和一个朝外的端口。控制一列里，Ibex CPU 接 L1，L1D 通到命令处理器，NoC endpoint 通到 L1I 并接这两个端口，DMA 接到 NoC endpoint。Tensor 单元里，Loader 与 Operand buffer 给一个 16 × 16 的 MAC 阵列供数，叠片画的 Output banks 分给上下两行，每行是一个 Row scan 加一个 Block formation，各自通到一个出口，即 outlet 0 与 outlet 1。每个出口引出一条粗线，经快通道的队列到一个 Ingress check，再进 Vector 单元里的 Vector core 0 或 Vector core 1。最下面是 L2 arbiter 与 128 KiB 的 L2；Loader、Ibex CPU、NoC endpoint 与 Vector core 0 用实线接到这条 arbiter，Vector core 1 用点线。虚线是命令处理器发往 Tensor 单元、两个 Vector 核与 DMA 的控制。标着 reject 与 error 的红色点划线从两个 Ingress check、两个 Vector 核与 Tensor 单元通到命令处理器。现状：已画，文件 `figures/fig-pe.pdf`。图注：PE 微架构（目标设计）。粗线是交接路径；红色点划线是错误与拒收；点线表示还没有定；叠片与队列符号不表示个数与深度。今天的原型 RTL 与它的差别包括：只有一个 Vector 核、一条快通道；L2 是 32 KiB、由 DMA 直接读写；执行期错误还到不了命令处理器。

<!-- P:sec4.1-p1 -->
同一型的 PE 组成 Mesh，Mesh 上的链路就是片上网络（NoC），Mesh 一级的 Control Core 经它派工（[图 4](#fig:system)）。一个 PE 有一个 Tensor 单元（由 16×16 个单元组成的输出驻留脉动阵列）和两个 Vector 核（[图 5](#fig:pe)）。Tensor 一侧与 Vector 一侧共用 PE 本地存储（128 KiB）和一个命令处理器，不共用算术硬件；描述符由一个 RISC-V 的 Ibex CPU [ref: Ibex] 交给命令处理器，这个 CPU 另有自己的 L1 存储。进每个 PE 的本地口（[图 4](#fig:system) 里的五边形，图上只画了进方向）按每拍 64 字节有效载荷规划 [TBD-D4: PE 口的通道与握手，等片上网络设计稿]；Mesh 边上的共享存储（L3）按每张 8×8 Mesh 128–256 MiB 规划 [TBD-D3: 共享存储进 Mesh 的带宽]。Mesh 的规模是规划点；host 接口、Control Core 与 L3 挂在 Mesh 的哪里还没有定。设计还没定的地方，[图 5](#fig:pe) 画成通用形态：两个 Vector 核画得一样，朝外的端口不标宽度，Vector core 1 到 PE 本地存储的连线是点线。

<!-- P:sec4.1-p2 -->
评估边界就是 PE 的接口。边界之内，PE 在 RTL 上评估，融合的 epilogue 用综合切片加周期模型评估。边界之外的一切都用模型：片上网络、共享存储与片外存储 [TBD-D3: 片上网络端点与共享存储进不进 RTL]；[图 4](#fig:system) 没有画这条边界，也没有画片外存储。**原型状态：**一个 Vector 核，32 KiB 的 PE 本地存储，32 位的流口，PE 之外没有 RTL；执行期错误到不了命令处理器。

### 4.2 Tensor 生产端（Tensor Producer） <a id="sec:producer"></a>

<!-- P:fig6-cap -->
<a id="fig:tensor"></a>**[图 6](#fig:tensor)**（通栏）画的是：目标设计的 Tensor 单元，分三个面板。面板 (a) 是阵列组织：Loader 从 L2 取数，权重经 Operand buffer 从上方进一个 16 × 16 的 MAC 阵列，激活从左侧进；Tile controller 用一条虚线接到阵列的边缘；叠片画的 Output banks 在阵列下方；一行字写着 2048 / 1024 / 256 MAC per cycle。面板 (b) 是一个 MAC 单元，自上而下：Input unpack（4-bit、8-bit 与 BF16 操作数）、Multipliers（4-bit × 4-bit）、Local reduce、Scale correction，以及带预载口的 Wide accumulator。面板 (c) 是出口处的块形成：Output banks 分给两个 Row scan；上面一套的 Block formation 展开成 Max exponent 与叠片画的 16 个 Quantizer，旁边有一个 Escape handling 选择器，下面一套只画成一个块；粗线通到 outlet 0 与 outlet 1（上面一条标着 capsule），一条红色点划线通到 error 端口。现状：已画，文件 `figures/fig-tensor.pdf`；设计里还没定的地方画成通用形态。图注：目标设计的 Tensor 单元；粗线是 capsule 的交接路径，点划线是送往命令处理器的错误路径。原型只有一个出口、一个输出 bank，两个操作数都在每个 tile 开始前装入，每拍 1024 / 512 / 256 次乘加，没有预载、escape 的处置选择与错误路径。

<!-- P:sec4.2-p1 -->
阵列的每个单元（[图 6](#fig:tensor)）是由 4 b × 4 b 乘法基元拼成的融合多精度 MAC，输入模式（原型里每拍取一对 BF16、一对 MXINT8、两对 FP8 或四对 FP4 操作数），带一个宽浮点累加器和一份 61 位的 snapshot。目标设计里，4 bit、8 bit 与 BF16 三档每个 PE 每拍分别做 2048、1024 与 256 次乘加 [TBD-D5: 各档对应哪些输入模式]。目标设计的这组速率印在[图 6](#fig:tensor) 上，是名义值，其中 BF16 一档暂定。设计里还没定的地方，图上画成通用形态：MAC 单元的内部、输出 bank 的个数、tile 控制器接入阵列的方式、预载的来源与 escape 的处置。

<!-- P:sec4.2-p2 -->
行扫描在出口形成输出块：取该行的最大指数，把 48 位的尾数收窄到 16 位，这是第一个收窄点；一个 tile 产出 16 个 capsule。硬 escape（出现 NaN 或无穷）让事务以错误结束；软 escape（块内下溢）缺省照常消费并计数。每个 tile 的固定开销按 5 拍规划 [TBD-D6: 这项开销的时序影响，尚未评估]。**原型状态：**按 tile 控制器的状态序列，每个 tile 固定 56 拍（不是仿真读数），而且要先把操作数搬进 Tensor 单元的 Operand buffer；escape 行被丢弃。

### 4.3 Tensor 到 Vector 的交接与失败可见（Tensor-to-Vector Hand-off and Fail-Visibility） <a id="sec:handoff"></a>

<!-- P:sec4.3-p1 -->
快通道把每个输出行作为一个 capsule，从阵列出口送到一个 Vector 核：256 位的 payload 加元数据（块大小、scale 格式、scale epoch、context、tag、行号与末行标记）。它是一条单向的 valid/ready FIFO，ready 信号卡住行扫描，所以消费端慢了就会反压到生产端。两个出口各有一套行扫描、块形成与快通道 [TBD-D1: 两条快通道的缓冲、credit 回程与核对放在哪一侧]。

<!-- P:sec4.3-p2 -->
每个 capsule 都在入口、消费端的操作数队列之前核对：块大小、scale 格式、scale epoch 与身份都必须与消费命令所期望的一致。任何失配都是失败可见的：它以自己的错误类型报到命令处理器，归属原事务，并阻止发布。另一个候选做法是改在派发时对照 [§4.5](#sec:commit) 的对象表来核对 scale。**原型状态：**只有一条快通道，只做三项格式核对；失配只会让消费端停住，直到大约 1023 拍后超时。

### 4.4 Vector 消费端与第二跳（Vector Consumer and the Second Hop） <a id="sec:consumer"></a>

<!-- P:fig7-cap -->
<a id="fig:vector"></a>**[图 7](#fig:vector)**（通栏）画的是：目标设计的 Vector 单元的框图。左边进来两条粗线，分别来自 outlet 0 与 outlet 1，各经快通道的队列到一个 Ingress check。Vector core 0 逐块画出：Ingress check、Operand queue、Scale adapter、带一个乘号与一个加号的 Lanes，一组 Reduce、exp、Top-k filter 与 Renorm + quantize（它们下面是留给 Output accumulators 的点线槽位），然后是 Write-back（payload 加 scale sidecar）与 Compact store，两者都通到右侧的 L2。沿这个核底边的 Resident read 横条把操作数从 L2 带回 Ingress check；Decode 接一条来自命令处理器的虚线。Vector core 1 折叠成一个 Ingress check、一个 Lanes 和一个标着 to be defined 的点线槽位，另有一条点线接到 L2。标着 reject 与 error 的红色点划线从两个核通到命令处理器。一条括线标出第二个出口、它的快通道与第二个核在单 Vector 的 PE 里去掉。现状：已画，文件 `figures/fig-vector.pdf`；两个 Vector 核的形态还没有定。图注：目标设计的 Vector 单元：Tensor 的两个出口各经一条快通道接一个 Vector 核（粗线：交接路径与入口核对）。点线的各项还没有定；括线标出单 Vector 的 PE 去掉的部分。原型状态：一个 16 通道的核；第二个核、乘加通道、exp、选前 k、scale sidecar 的写回，以及拒收与错误的上报，都还没有进 RTL。

<!-- P:sec4.4-p1 -->
原型的 Vector 核在块浮点域里计算：16 条通道，各是 16 位的尾数，每块共享一个指数。它提供残差加、重标定、块内取最大与求和、在一个 40 位窗口内做的平方和，以及打包；目标设计（[图 7](#fig:vector)）再加上索引分数的后处理与选前 $k$。图上 core 0 只画到块一级，core 1 折叠；框的大小不表示算力；从 PE 本地存储读回的操作数同样经过入口核对。设计要求是屏蔽一个 Vector 核之后 PE 仍能做全部运算；候选是一个流水核加一个通用核，或两个相同的核 [TBD-D1: 两个 Vector 核的形态、宽度与分工]。

<!-- P:sec4.4-p2 -->
第二跳把结果写进 PE 本地存储，或者送给下一个 GEMM。写入时先做重规格化（第二个收窄点），再把 payload 与 scale sidecar 里的块指数一起提交，供以后再消费。送给下一个 GEMM 时，先转换成那个 GEMM 的输入格式。**原型状态：**写回只存 payload，所以往返不闭环，送给下一个 GEMM 的通路也没有闭环；平方和还没有命令能调用。

### 4.5 L2、提交协议与控制（L2, Commit Protocol and Control） <a id="sec:commit"></a>

<!-- P:sec4.5-p1 -->
PE 本地存储在行为模型与单口宏两种实现下遵守同一份合同：一个 bank 同一时刻只服务一次访问，只对真正服务过的请求给出应答；子字更新（scale sidecar 的一项）原子执行。一次提交写入 payload 与 scale；命令处理器把对象记进一张有限的表，发放读租约，并在事务无错退休后发布它。命令处理器在取描述符时拒收非法描述符，按各单元的 credit 派发，并让每条命令的终态与 credit 恰好结算一次 [TBD-D7: L2 合同与写回设计稿未定稿]。**原型状态：**在宏实现下，冲突的读可能返回带有效标记的旧数据；没有对象表、租约与发布。

### 4.6 一份 RTL，几种交接（One RTL, Several Hand-offs） <a id="sec:one-rtl"></a>

<!-- P:sec4.6-p1 -->
至多四种交接方式是同一份 RTL 上的编译期配置，只在交接处不同。S-D 把块形成换成出口转换器与标量通道；B-M 加上 scale 的写回与读回；S-M 加上标量存储 [TBD-E4: 标量经存储这一种做 RTL 还是用模型]。**原型状态：**只实现了 B-D。

## 5 评估方法（Evaluation Methodology） <a id="sec:method"></a>

<!-- P:fig8-cap -->
<a id="fig:flow"></a>**[图 8](#fig:flow)**（单栏）画的是：两列方框的流程图。左列是输入：金标与测试（Golden model + tests）、合成张量、RTL 与配置、流程与 PDK 的设定、负载清单。右列是证据形式：RTL 仿真、综合切片、布线后 EDA 估计、解析推导，以及一个点线框里的模型结果。实线把金标、合成张量与 RTL 接到 RTL 仿真，把 RTL 与流程设定接到综合切片和布线后 EDA 估计，把负载清单接到解析推导。一条点线从负载清单出发，经一个标着 Model、to be defined 的点线框，接到模型结果。现状：已画，文件 `figures/fig-flow.pdf`；建模一步是留空的槽位。图注：规划中的评估流程。左列是输入，右列是每个数所标注的证据形式。负载清单由解析推导得到，不经过模型。点线部分还没有定：用哪套模型还没选，它的输入只画了一项。跑合成张量的数值前端没有画出。

### 5.1 配置与证据形式（Configurations and Evidence Types） <a id="sec:configs"></a>

<!-- P:tab4-cap -->
<a id="tab:configs"></a>**[表 4](#tab:configs)**（单栏）表注：配置与证据形式。

| 配置 | 定义 |
|---|---|
| Prototype | 今天的 RTL；仿真时 PE 本地存储用行为级的双口模型 |
| Corrected | 加一份带版本的修正清单；主实验在它上面做 |
| Projected | 再加更多的 PE、片上网络与共享存储；结果是投影 |
| （单独列出） | 目标设计里还没有进 RTL 的设计点 |
| 证据形式：RTL 仿真、周期模型、解析推导、综合切片、布线后 EDA 估计。 | |

<!-- P:sec5.1-p1 -->
每个数带两个标注：它出自三个配置里的哪一个 [TBD-N: 三个配置的中性叫法]，以及它的证据形式（[表 4](#tab:configs)、[图 8](#fig:flow)）。Corrected 的修正清单里有错误上报到命令处理器、单口本地存储宏的访问合同、scale 写回 [TBD-D7: 修正清单的定稿，等合入计划]。物理结果一律不叫「测量」。<!-- 译注：(1) 英文稿用术语宏 \Lii（印出来是 L2）的地方，本稿写「PE 本地存储」或「本地存储」：对齐检查器按字面比数字、不展开术语宏，中文写成 L2 会多出一个 2。(2) Prototype / Corrected / Projected 是英文稿里三个配置的暂用名（术语宏 \cfgAsBuilt / \cfgCorrected / \cfgProjected），依次指今天的 RTL、修正后的 PE、投影的系统。 -->

### 5.2 指标、运行区间与 K（Metrics, Operating Regimes and K） <a id="sec:metrics"></a>

<!-- P:sec5.2-p1 -->
时延与吞吐按三种统计范围报告：完整链的端到端周期、稳态下有效结果的吞吐、交接与消费阶段的局部周期。局部快不能推出端到端快；端到端持平，也不能说明两种交接的成本相同。其余指标是面积与时序、SRAM 事务、同一误差预算下的数值误差，以及能耗（动作计数乘有来源的单价，再加漏电；没有来源的成本留空）。运行区间有两个：数据驻留在 PE 本地存储的区间（操作数已经在本地存储里），与供数受限区间（操作数的供给受 PE 对外口限制） [TBD-D4: 供数受限区间在规划口宽下的定义]。一次 GEMM 的总 $K$ 与一个 tile 的 $K_c$ 分开写；各交接方式在对它们都合法的 $K$ 范围内比较 [TBD-D7: 目标设计的操作数装载器之下 K 的合法范围]。

### 5.3 数值协议（Numerical Protocol） <a id="sec:numerics"></a>

<!-- P:sec5.3-p1 -->
数值顺序先冻结，再比性能（[§3.1](#sec:placements)），一直冻结到最终消费的时点。硬件一侧的语义由逐位的参考模型（金标）定义；各交接方式用同一批张量与种子。输入是合成张量：[§5.4](#sec:workload-method) 的几个模型我们跑不了，也没有用它们的权重。张量的形状取自负载里的矩阵乘；激活与缓存条目的量化照参考实现的规则，权重的量化规则参考实现里没有 [TBD-E3: 合成张量的取值分布与权重量化规则]。这里的「质量」指相对参考精度结果的数值误差，不是任务指标。

### 5.4 负载：数什么、怎么数（Workload: What Is Counted and How） <a id="sec:workload-method"></a>

<!-- P:tab5-cap -->
<a id="tab:mac-share"></a>**[表 5](#tab:mac-share)**（单栏）表注：每个新 token 的乘加（MAC）按操作数数据类型的占比，类型照参考实现（解析推导）。表脚：ᵃ 权重是 4 bit。ᵇ 权重文件里存的是 8 bit。V4.1-Flash 在 1M 一档按它的报告的口径。

| 操作数；8K / 1M 时的占比（%） | V4-Pro | V4-Flash | V4.1-Flash |
|---|---:|---:|---:|
| 4 × 4 bit（索引打分） | 0.9 / 42.5 | 2.4 / 64.3 | 1.2 / 38.3 |
| 4 × 8 bit（路由专家）ᵃ | 44.2 / 15.9 | 44.0 / 9.3 | 47.3 / 29.5 |
| 8 × 8 bit（投影、共享专家） | 34.0 / 12.3 | 29.9 / 6.3 | 30.6 / 19.1 |
| BF16 × 缓存（注意力核心） | 9.7 / 25.3 | 7.8 / 16.8 | 9.0 / 5.6 |
| BF16 × BF16（输出投影）ᵇ | 7.5 / 2.7 | 9.8 / 2.1 | 7.5 / 4.7 |
| FP32（其余各矩阵） | 3.6 / 1.3 | 6.2 / 1.3 | 4.4 / 2.8 |

<!-- P:sec5.4-p1 -->
负载取 [§2.4](#sec:bg-workload) 那三个模型的解码一步 [@DeepSeekAI2026V4ProHF; @DeepSeekAI2026V41FlashHF] [ref: DeepSeek-V4-Flash model repository]；V4-Flash 用 V4-Pro 的代码换上它自己的配置来数。预填之后，参考实现每步只送一个 token 进模型，所以计数的单位是每条序列、每个新 token，上下文长度记作 $L$。乘加只计矩阵乘里的，其余运算另行计数。

<!-- P:sec5.4-p2 -->
这些计数是解析推导，不跑模型。每个矩阵乘记「输出行数 × 内积长度 × 层数」，其余运算按源码里的循环界数。操作数类型照参考实现的代码（[表 5](#tab:mac-share)）；索引打分按作者的说法记作 4 bit × 4 bit，而代码里是放在 BF16 里算的。V4.1-Flash 在 64K 及以上各档，后面重新打分的层按它的技术报告的口径、只对候选池计数 [@DeepSeekAI2026V41Flash]；参考实现的代码是对全部条目打分，照它算 1M 时每个 token 的乘加合计多 58.8%。

### 5.5 模型保真与性能数据的来源（Model Fidelity and the Source of Performance Data） <a id="sec:fidelity"></a>

<!-- P:sec5.5-p1 -->
单个 PE 上的时延读数来自 RTL 仿真；生产端融合的那一种交接方式与一个 PE 以上的一切都要靠模型 [TBD-P: 性能数据的来源]。不管用哪个模型，有两条不变：它的结果标明是模型结果；负载运算清单是模型的输入，不是结果。模型若对着 RTL 校准，要做两轮：先在 Prototype 上，再在 Corrected 上并换一批新的留出点；模型复现了 Prototype 的一个已知错误行为，只算「与 RTL 一致」，不算有效的性能样本。

### 5.6 物理实现（Physical Implementation） <a id="sec:physical"></a>

<!-- P:sec5.6-p1 -->
RTL 用开源流程 OpenROAD-flow-scripts 在 ASAP7 预测型 7 nm PDK 上实现 [ref: ASAP7 PDK; open-source implementation flow]。面积与时序取自综合与布局布线的运行，前提是文中写明的库、约束与 SRAM 模型；每个数都是布线后 EDA 估计，不是硅测量。各趟运行只用单个工艺角；SRAM 宏的 liberty 是生成的，其中漏电为零、最小周期为零是模型缺项，不表示没有开销。在有基于活动率的方法之前不报功耗。

## 6 结果（Results） <a id="sec:results"></a>

<!-- P:sec6-p0 -->
今天只有 [§6.1](#sec:res-workload) 与 [§6.6](#sec:res-impl) 有结果；其余各小节写明要做的实验、它的图（主比较是 [图 9](#fig:payoff)）与读法。

<!-- P:fig9-cap -->
<a id="fig:payoff"></a>**[图 9](#fig:payoff)**（通栏）要画：何时划算。每个消费者档次、每个运行区间一个面板；面板里是各交接方式在三种统计范围下随 $K$ 的变化；RTL 仿真与模型的结果并排、共用同一尺度；标出块表示不划算的区间。现状：占位，等实验。图注：保留块表示在哪里划算、在哪里不划算：各交接方式按消费者档次、运行区间与 $K$，在 [§5.2](#sec:metrics) 的三种统计范围下比较；RTL 仿真与模型的结果分面板画、共用同一尺度。

### 6.1 负载刻画（Workload Characterization） <a id="sec:res-workload"></a>

<!-- P:sec6.1-p1 -->
按解析推导，解码一步的运算构成随上下文变长而翻转（[图 2](#fig:workload)、[表 1](#tab:workload-gen)）：8K 时前馈专家占乘加的一半以上，索引打分只占 0.9%–2.4%；1M 时最大的一部分是索引打分。随 $L$ 增长的只有索引打分，以及 V4-Pro 与 V4-Flash 里每 128 个 token 留一条的那些层的注意力核心；所以从 8K 到 1M，每个 token 的乘加数涨到 2.77 倍、4.75 倍、1.60 倍（依次是 V4-Pro、V4-Flash、V4.1-Flash）。

<!-- P:sec6.1-p2 -->
长上下文下，矩阵乘之外（non-GEMM）次数最多的运算跟着索引打分与注意力核心走，两者都是每 128 次乘加对应一次，每个模型都一样（[表 1](#tab:workload-gen)）。两个操作数都是 4 bit 的乘加只出现在索引打分里（[表 5](#tab:mac-share)）。在参考实现里，scale 出现在矩阵乘的输入一侧与缓存里，矩阵乘的输出是标量；所以每个新 token 有 1.39–3.31 百万个元素要在运行时动态量化到 8 bit。保持块缩放的交接能省掉其中多少，[§3.3](#sec:tiers) 的各档消费者又各对应负载里的哪些运算，都还没有结果 [TBD-E4: 能省掉多少次量化；负载运算与消费者档次的对应]。

### 6.2 正确性、失败可见与数值（Correctness, Fail-Visibility and Numerics） <a id="sec:res-correct"></a>

<!-- P:fig10-cap -->
<a id="fig:correct"></a>**[图 10](#fig:correct)**（单栏）要画：三项检查放进一个紧凑面板：(a) 全 PE 的算术闭环，对照参考模型；(b) 每一类注入的失配落到哪个终态；(c) 各交接方式在合成张量上的数值误差。现状：占位，等实验。图注：正确性 (a)、失败可见 (b) 与数值 (c)，即 [§6.2](#sec:res-correct) 的三项检查。

<!-- P:sec6.2-p1 -->
比代价之前先做三项检查（[图 10](#fig:correct)）。(a) 全 PE 的算术闭环：一条完整链写进 PE 本地存储的各行读回后与逐位参考模型比对，并写明是否覆盖输出块的指数 [TBD-E1: 全 PE 算术闭环，RTL 仿真]。(b) 失败可见：每一类可达的失配（例如 scale 的 epoch 被篡改、结果在被消费之前被覆写）都必须以错误状态结束，credit 恰好结算一次 [TBD-E2: 故障注入的结局，RTL 仿真]。(c) 数值：报告各交接方式在 [§5.3](#sec:numerics) 的合成张量上相对参考精度结果的误差 [TBD-E3: 合成输入上的数值质量；escape 指标的定义]。**原型状态：**从 GEMM 到残差加的这条链今天只做了分段验证，全 PE 一级只验了「能跑完」。

### 6.3 何时划算（When Does It Pay Off） <a id="sec:res-payoff"></a>

<!-- P:sec6.3-p1 -->
主实验比较 [表 2](#tab:placements) 的五种交接方式，覆盖 [§3.3](#sec:tiers) 的各档消费者、两个运行区间与 $K$（[图 9](#fig:payoff)）。S-E 同时报乐观界与校准估计 [TBD-E4: 交接方式扫描的结果，RTL 仿真]。

<!-- P:sec6.3-p2 -->
扫描的结果对照命题 A 来读（[§2.3](#sec:bg-hypotheses)），三种统计范围各读一遍。若存在边界，就用三个量来表述：融合是否可行、结果要活多久、元数据事务的粒度（[§6.4](#sec:res-metadata)）。块表示不划算的区间在 [图 9](#fig:payoff) 上标出来；没有出现翻转点，也照实报告。**原型状态：**各交接方式之间还没有做过比较；在 128 KiB 的本地存储进 RTL 之前，[§3.1](#sec:placements) 的主比较只有模型一级的依据。

### 6.4 元数据事务与存储代价（Metadata Transactions and Storage Cost） <a id="sec:res-metadata"></a>

<!-- P:fig11-cap -->
<a id="fig:metadata"></a>**[图 11](#fig:metadata)**（单栏）要画：元数据事务（命题 B）：B-M 与 S-M 的六项成本，按元数据布局分列，横轴是每次 sidecar 访问合并的块数；只有存在翻转点时才标出。现状：占位，等实验。图注：命题 B 的元数据事务账：B-M 与 S-M 每元素的成本，横轴是每次 scale sidecar 访问合并的块数，按元数据布局分列。只有存在翻转点时才标出。

<!-- P:sec6.4-p1 -->
命题 B 用一份事务账来检验，这份账先按解析方式算出，之后才考虑做任何机制（[图 11](#fig:metadata)）。对 scale sidecar 的每一种布局，我们按 [§3.6](#sec:metadata) 的六项成本给 B-M 与 S-M 记账。我们报告 scale 元数据占用的存储，以及是否存在翻转点。把同一 sidecar 行的各次更新做有界合并，只有当它能把翻转点移到写合并基线做不到的位置时，才写成机制 [TBD-E5: 元数据事务账]。

### 6.5 让交接失败可见的代价（The Cost of a Fail-Visible Hand-off） <a id="sec:res-failvis"></a>

<!-- P:fig12-cap -->
<a id="fig:failvis-cost"></a>**[图 12](#fig:failvis-cost)**（单栏）要画：让交接失败可见的代价（累加式拆解）：从裸的块直接交接起，依次加上消费端核对、错误汇聚、带元数据提交、第二跳。现状：占位，等实验。图注：让交接失败可见的代价，在裸的 B-D 通路上一步一步加。

<!-- P:sec6.5-p1 -->
失败可见的代价按增量报告，起点是裸的 B-D 交接（[图 12](#fig:failvis-cost)）。依次加上：消费端入口的核对；执行期错误在命令处理器处的汇聚；payload 连同它的 scale 元数据一起提交；第二跳，即把存下的结果读回再消费。每一步增量记它的实现代价，是布线后 EDA 估计 [TBD-E8: 累加式代价拆解]。「派发时核对」与「数据通路上核对」的对照是有条件的：两种做法共用对象表、租约与发布规则，只差在核对放在哪里、做多少次。

### 6.6 实现（Implementation） <a id="sec:res-impl"></a>

<!-- P:fig13-cap -->
<a id="fig:layout"></a>**[图 13](#fig:layout)**（单栏）画的是：整个 die 的版图图像，die 是正方形。标准单元是深色底上成片的灰色，占了 die 的大部分；33 个 SRAM 宏是带斜纹的暗红色小矩形，在中间偏左排成四行。带名字的黑框标出 Operand buffer、L2 与 L1 的宏，以及左下角 Command processor、Vector unit 与 Ibex CPU 各自的大部分单元；其余的大片区域标作 Tensor unit。现状：已按布线后的设计数据画出，文件 `figures/fig-layout.pdf`。图注：一个 PE 的布线后版图（ASAP7 预测型 PDK；EDA 结果，不是硅；中间版本），按布线后的设计数据绘制。框标出 SRAM 宏（L1、L2、Operand buffer）或一个模块的大部分单元；其余部分是 Tensor 单元。这一趟的 RTL 早于 Vector 的平方和修正，只有一个 Vector 核，L2 为 32 KiB；各趟的数据见[表 6](#tab:layout-runs)。

<!-- P:tab6-cap -->
<a id="tab:layout-runs"></a>**[表 6](#tab:layout-runs)**（单栏）表注：各趟布局布线：[图 13](#fig:layout) 的 PE，以及它的两个单元各自单独跑的一趟（ASAP7，布线后；中间版本）。表脚：die 都是正方形。(a) 只计逻辑单元（不含填充单元与 tap 单元）；面积是各单元库内占位面积之和。(b) 流程配置里交给工具的时钟周期约束；不是达成的周期，这里不报告任何时序结果。(c) 同一份 RTL 的模块各自单独跑的块级一趟；不是从版图图上裁下来的。每跑完一次全流程，图与表重出一次。

| 趟 | die 边长（µm） | 标准单元数 (a) | 单元面积 (a)（µm<sup>2</sup>） | SRAM 宏个数 | 时钟约束 (b)（ps） |
|---|---:|---:|---:|---:|---:|
| 整个 PE（[图 13](#fig:layout)） | 1428.5 | 3,434,117 | 397,242 | 33 | 12,000 |
| Tensor 单元 (c) | 903.2 | 3,067,762 | 352,109 | 12 | 1,670 |
| Vector 单元 (c) | 330.5 | 265,898 | 28,560 | 0 | 1,670 |

<!-- P:sec6.6-p1 -->
[图 13](#fig:layout) 是今天有完整布线后版图的最大对象，即 ASAP7 上的整个 PE；[表 6](#tab:layout-runs) 另列它的两个单元各一趟块级运行。图上的灰色表示哪里有标准单元，不表示有多密；设计是扁平布局的，所以框只是标示；DMA 与快通道 FIFO 太小，没有画框。三趟用的是同一份 RTL，它早于平方和单元的一次数值修正；三趟的差别在时钟约束与流程配方。三趟的时序都没有收敛；整个 PE 这一趟还剩的布线违例随公开的源码一起列出。Corrected 与目标设计按部件的面积与时序还没有 [TBD-E8: 按部件的分解]。

### 6.7 系统级投影（System-Level Projection） <a id="sec:res-system"></a>

<!-- P:fig14-cap -->
<a id="fig:system-proj"></a>**[图 14](#fig:system-proj)**（单栏）要画：系统级投影：在单个 PE 上看到的交接收益，加上传输、向别的 PE 发布与负载映射之后是否还在。现状：占位；性能数据的来源未定。图注：系统级投影。每个点都是模型结果，不是 RTL 仿真；模型还没有定。

<!-- P:sec6.7-p1 -->
最后一个问题：在单个 PE 上看到的收益，加上 PE 之间的传输、向别的 PE 发布与负载映射之后是否还在（[图 14](#fig:system-proj)）。Projected 用模型来回答（[§4.1](#sec:pe-org)）；这里不给吞吐、时延与瓶颈的数 [TBD-P: 性能数据的来源] [TBD-E10: 系统级投影]。若模型里立不起一条跨 PE 的事务链，结果就降为有界的敏感性分析。

## 7 相关工作（Related Work） <a id="sec:related"></a>

<!-- P:tab7-cap -->
<a id="tab:prior"></a>**[表 7](#tab:prior)**（单栏）表注：最接近的前作，按机制分组：每一类工作回答了什么、留下什么没答。

| 回答了什么 | 留下什么没答 |
|---|---|
| *矩阵乘之外的块格式*：DB-Attn、MXInt ViT、MASE、BBAL | |
| 块格式可以跨过矩阵算子与非矩阵算子之间的边界 | 在彼此独立、被复用的单元之间，保留块表示何时划算 |
| *量产设计的交接*：Blackwell 与 cuBLAS、MTIA 2i、Tenstorrent | |
| 今天的做法：S-E、S-D，以及 S-M 加打包 | 交接位置何时改变代价与数值 |
| *标签与写合并*：CHERI、tagged-token 数据流、Triggered Instructions | |
| 标签与数据原子绑定；在消费端核对标签；写合并 | 凭租约重读的多行数值对象，以及它的代价 |

<!-- P:sec7-p1 -->
**矩阵引擎之外的块格式计算。** 块格式能跨过矩阵算子与非矩阵算子之间的边界，这一点前作已经做到了，做法是把它放在算子专用的引擎里。DB-Attn 让块浮点矩阵乘与 softmax 共享指数，并有一个 RTL 级的 softmax 引擎 [@Wang2025DBAttn]。MXInt ViT 把视觉 Transformer 的全部算子映射进 MXInt 域 [ref: MXInt ViT]；MASE 生成数据流加速器，算子之间的张量一直保持 MXInt [ref: MASE]。BBAL 加了一个用 BBFP 格式的非线性单元，但输入要先从 FP16 转回来 [@Han2025BBAL]。本文问的是另一件事：在彼此独立、都被复用的单元之间，保留块表示何时划算；各种交接方式作为同一份 RTL 上的配置来比较。

<!-- P:sec7-p2 -->
**量产设计的交接与融合 epilogue。** [§2.2](#sec:bg-today) 盘点的做法里有三种对得上本文比较的交接方式，按[表 7](#tab:prior) 的次序依次是 S-E、S-D，以及 S-M 加打包。本文的比较只在同一份 RTL 的各种交接方式之间做，不跨工艺。

<!-- P:sec7-p3 -->
**数据与元数据的一致性、标签与写合并。** CHERI 把 tag 与它的数据原子绑定，普通写会清掉 tag，粒度是单个 capability [ref: CHERI ISA specification]；它不覆盖这样的情形：多行的数值对象，在统计量算完之后凭租约被再次读取。带标签令牌的数据流机器与 Triggered Instructions 里的 tag 比较，是在消费端核对的先例 [ref: tagged-token dataflow; Triggered Instructions]。写合并是常见做法，也是本文在命题 B 上的强基线（[§3.6](#sec:metadata)），不是贡献。提交、租约与发布这几条规则（[§3.4](#sec:retain)、[§4.5](#sec:commit)）属于本文的工程机制：本文报告它的代价，不主张「正确处理元数据」本身是新的。

## 8 局限（Limitations） <a id="sec:limits"></a>

<!-- P:sec8-p1 -->
物理结果是 ASAP7 预测型 PDK 上、单工艺角下的布线后 EDA 估计，SRAM 的时序模型是生成件；本文不主张硅、签核或频率。每个结果都写明它用的是哪一种 PE 本地存储合同；行为双口模型下的性能，不与单口宏下的面积与时序配在一起。<!-- 译注：英文稿这里用术语宏 \Lii（印出来是 L2，即 PE 内的本地存储）；中文写「PE 本地存储」，是为了让对齐检查器两边数到的数字一致。 -->正文写的是目标设计；原型还缺什么，见 [§4](#sec:uarch)。

<!-- P:sec8-p2 -->
系统级结果是模型给出的投影；在单个 PE 上做的校准，不会自动传递到片上网络、共享存储或片外存储。负载的数是对同一个模型系列的解码一步数出来的解析计数，不是测量。数值实验用合成张量：报告的是所述分布下的数值误差，对模型质量不下任何结论。目标设计偏离参考实现的地方也一样：注意力核心的查询量化到 8 bit（参考实现是 BF16）；在线 softmax 与选前 $k$ 的做法可以与参考内核不同。融合只评了标量 epilogue 这一种，没有评在块域里做的融合。第三档消费者只做最小实例，不是完整的 RMSNorm。

## 9 未来工作（Future Work） <a id="sec:future"></a>

<!-- P:sec9-p1 -->
3D 堆叠与 3D Mesh，是本文所取的 2D Mesh 的延伸。SRAM 没有检错纠错；要加，得等有更多的存储宏可选，或换一个工艺。PE 不挂调试模块，因为仿真用不到它。Mesh 一级的 Control Core 不在本文的评估之内；以后可以换成乱序核，更大的 Mesh 也可以按控制域各配一个核。

<!-- P:sec9-p2 -->
Mesh 用一型 PE，并在空闲上报与任务描述符里预留了能力位；一张 Mesh 里混排两型 PE 的异构 Mesh，以及面向它的任务映射，留待以后。

## 10 结论（Conclusion） <a id="sec:conclusion"></a>

<!-- P:sec10-p1 -->
本文问的是：GEMM 的结果跨过 PE 里矩阵到向量的交接时，何时应当保持块缩放格式，而不是转成标量跨过去、或在融合 epilogue 里就地消费；让这个交接失败可见，又要付出什么。答案将由交接方式扫描与代价拆解给出，用三个量来表述：融合是否可行、结果要保留多久、元数据事务的粒度 [TBD-E4: 等结果出来后写]。这个答案的适用范围由它的证据划定：数值误差是在合成输入上评的，交接方式是在同一份 RTL 内比的，物理代价是布线后 EDA 估计，不是硅测量。
