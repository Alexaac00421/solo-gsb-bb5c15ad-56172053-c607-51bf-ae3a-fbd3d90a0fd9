# 数控刀路禁入区审查服务

基于 **FastAPI + PostgreSQL** 的 HTTP 服务，用于登记毫米制二维禁入区并对 G-code 刀路进行连续碰撞审查，出具不可变审查报告。

## 功能概览

- 禁区以**毫米制二维多边形 + 闭合 Z 高度范围 `[z_min, z_max]`** 登记；
- 禁区几何采用**不可变版本**：每次修改生成新版本，旧版本永久保留；
- **机床禁区基线**（`/baselines`，见下文「机床禁区基线」）：按**机床编号**固化一组
  **互不重复的禁区编号 + 明确版本**（首版为 1），每次修订产生**递增且不可变**的新版本，
  旧版仍可查询；单项审查、批量任务与分块上传建会话可用 **机床编号 + 基线版本**
  代替原 `zones`，审查时解析为对应禁区版本快照，报告继续固化 `used_zone_versions`；
- 审查输入：禁区编号及**明确版本**（或机床基线引用）、毫米制初始刀尖坐标 `(x, y, z)`、
  初始刀具半径（mm）、G-code 文本；
- **可选多刀半径映射**（请求中 `"tool_radii": {刀号: 半径mm}` 启用）：同一份 G-code 可使用多把刀，
  见下文「多刀审查」；不传映射时 `T` 仍被忽略，单刀请求与旧报告完全兼容；
- G-code 模态解析：`G0/G1/G2/G3`、`G17`、`G20/G21`、`G90/G91`；缺省轴沿用前值；
  - `G20`（英寸）坐标自动换算为毫米（×25.4），`G21` 为默认公制；
  - 圆弧仅支持 **XY 平面恒定 Z**；`I/J` 始终**相对弧起点**；同起终点 + 非零 I/J 表示**整圆**；
- 按程序顺序检查每一段连续运动：
  - 刀尖 Z 位于禁区闭合高度范围内，**且**
  - 水平路径到填充多边形的距离 **不大于刀具半径**
  - 即判定碰撞，**边界接触也算碰撞**；
  - 线段通过二次不等式**精确求解路径-多边形距离区间**，圆弧通过精确弧-边距离 + 二分定位，
    **不会因只采样端点而漏掉途中碰撞**；
- 报告记录：所用禁区版本、输入摘要（行数、运动段数、起止点、刀半径、G-code SHA-256）、
  **首个碰撞的 G-code 原行号与禁区编号**，或无碰撞结论；
- **可选全程最小水平净间隙**（请求中 `"include_min_clearance": true` 启用）：
  对每段运动仅在刀尖 Z 处于该禁区**闭合高度范围**内的部分，求连续 XY 路径到填充多边形的
  最小距离减刀具半径；直线、圆弧、整圆及运动途中进入高度范围均精确覆盖。
  **刀具外沿恰好接触边界（距离 = 刀半径）时净间隙为 0**；刀尖路径落在填充多边形内部/
  边界上（距离 0）时净间隙为 **-刀半径（负）**。返回毫米制最小净间隙、对应原行号、
  刀尖坐标 `[x, y, z]` 与禁区编号；等值时按**运动顺序 → 段内进度 → 禁区编号**选取；
  全程不在任何禁区高度内则结果为 `null`；无运动段按**初始刀位**计算。
  该结果**随报告固化**，且与首碰撞结论相互独立；
- **多刀审查**（可选 `tool_radii` 映射）：首碰撞与最小净间隙均按**事件发生时生效刀具的半径**
  计算，报告对两种命中分别固化原行号、**刀号与半径**（初始刀位的刀号为 `null`）；
  等值先按**执行顺序**，再按既有段内进度与禁区编号裁决。未传映射时 `T` 忽略，旧行为不变；
- **多刀执行事件轨迹**（`tool_radii` 启用时随报告固化，见下文「执行事件轨迹」）：
  按执行顺序记录**初始刀位、每次 T 切换时的静止刀位（含与运动同行）与每段运动**，
  每项含原行号、刀号、半径、起止坐标与命中禁区编号（或空），可逐事件回看；
  首碰撞即轨迹中**首个命中事件**，可选最小净间隙沿同一事件顺序裁决；
- **批量审查**（`POST /reviews/batch`，见下文「批量审查」）：一次提交带唯一
  `batch_id` 的 **1～50 项有序任务**，每项独立给出禁区版本、初始刀尖坐标、刀具半径、
  G-code 及可选最小净间隙/多刀参数；**同一事务**中先校验整批并固定各项禁区版本快照，
  任一项非法返回**逐项错误**且整批不落报告，全部通过才按输入顺序生成不可变报告；
  相同 `batch_id` 重放按内容判定幂等/冲突；
- **长 G-code 可恢复分块上传**（`/uploads`，见下文「分块上传审查」）：车间网络不稳时
  先创建上传会话（**固定禁区编号及明确版本**、初始刀尖坐标、刀半径与可选多刀/
  最小净间隙设置，返回会话标识），再以 **0 起序号**乱序提交 UTF-8 文本块
  （单块 ≤ 64 KiB、会话总量 ≤ 8 MiB；可查询已收序号；**同号同内容重传返回原回执**、
  同号异内容冲突不覆盖）；完成时声明**正整数块数**与**拼接文本 SHA-256**，
  仅在 0..块数-1 齐全、摘要一致且整份 G-code 通过既有审查校验时，
  按与 `POST /reviews` **完全相同的口径**生成一份不可变报告（行号按拼接原文）；
  相同完成声明并发/重放返回**同一报告**，成功完成后不同声明冲突且拒绝新块；
  全部状态落库，**跨服务重启保留**；
- **工单刀路审查放行**（`/releases`，见下文「工单刀路审查放行」）：车间按
  **工单**锁定一台机床的刀路审查放行结果，提交工单号、机床编号、预期基线版本
  与 **1～50 个有序且互不重复的报告编号**；全部报告必须**无碰撞**、固化的基线
  引用与该机床/版本一致、固化的禁区版本与该基线清单一致，且预期版本仍是该机床
  **当前版本**时才放行；基线修订与放行并发按**同一版本状态**串行判定，
  成功后固化工单、报告顺序、基线版本与放行时间，按工单查询的结果**永不随
  后续修订改变**；同工单同内容重试返回首次结果（`200`），异内容 `409` 冲突；
  基线/报告不存在、版本过期、报告不合格一律拒绝且**不留部分记录**；
- 报告**一旦生成不可变**，后续禁区更新新版本不影响任何旧报告；
- 非法几何、负/非法刀具半径、非法圆弧、不支持的运动/坐标系指令、非法开关类型，以及多刀模式下
  非整数/负数 `T`、同行多个 `T`、未映射刀号、非法映射半径一律返回 `422`，**不留任何报告**。

## 一键启动（Docker Compose）

要求：Docker 与 Docker Compose v2。

```bash
docker compose up --build
```

启动后：

- API 服务地址：`http://localhost:8080`
- 健康检查：`GET http://localhost:8080/health`
- 交互式 API 文档（Swagger UI）：`http://localhost:8080/docs`
- OpenAPI 描述：`http://localhost:8080/openapi.json`

首次启动时应用会自动连接 PostgreSQL 并完成数据库表初始化（`create_all`），无需手工建表；
对**升级前的旧库**会幂等补齐 `reports` 表的最小净间隙列（`ALTER TABLE ... ADD COLUMN`），
v1.2 的多刀命中刀号/半径列（`collision_tool_no` / `collision_tool_radius`），
以及 v1.3 的执行事件轨迹列（`execution_trace`）；v1.4 新增的 `batches` 批量审查表、
v1.5 新增的 `upload_sessions` / `upload_chunks` 分块上传表、
v1.6 新增的 `zone_baselines` 机床基线表
与 v1.7 新增的 `machine_locks` 机床串行锁表 / `work_order_releases`
工单放行表均由 `create_all` 对旧库幂等建出。
旧报告读取为 `min_clearance_enabled=false`、`min_clearance=null`，多刀字段为 `null`，
`execution_trace=null`，旧请求行为不变。

停止并保留数据：

```bash
docker compose down
```

彻底清空数据库卷：

```bash
docker compose down -v
```

## 配置

通过环境变量配置（见 `.env.example`）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DATABASE_URL` | `postgresql+psycopg://cnc:cnc_password@db:5432/cnc_audit` | PostgreSQL 连接串（SQLAlchemy + psycopg v3） |
| `HOST` | `0.0.0.0` | 服务监听地址 |
| `PORT` | `8080` | 服务监听端口，容器内固定暴露 `8080` |

`docker-compose.yml` 中包含：

- `db`：`postgres:16-alpine`，库名/用户/密码 `cnc_audit` / `cnc` / `cnc_password`，数据卷 `pgdata`，带健康检查；
- `api`：本仓库构建的镜像，等待数据库健康后启动。

本地非容器运行：

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export DATABASE_URL="postgresql+psycopg://cnc:cnc_password@localhost:5432/cnc_audit"
uvicorn app.main:app --host 0.0.0.0 --port 8080
# 也可用 SQLite 做本地试验：
# export DATABASE_URL="sqlite:///./cnc_audit.db"
```

## HTTP API

### 1. 登记禁区（版本 1）

`POST /zones`

```json
{
  "zone_no": 1,
  "polygon": [[0, 0], [10, 0], [10, 10], [0, 10]],
  "z_min": -5.0,
  "z_max": 5.0,
  "description": "机床基座（毫米）"
}
```

`zone_no` 省略时自动分配递增编号。多边形至少 3 个不共线、不重合顶点，不允许自相交/自接触；`z_min <= z_max`。非法几何返回 `422`，编号冲突返回 `409`。

### 2. 禁区列表 / 详情（含全部版本）

- `GET /zones`
- `GET /zones/{zone_no}`

### 3. 登记不可变新版本（修改几何）

`POST /zones/{zone_no}/versions`，请求体同几何部分；版本号自动在上一版本基础上 +1，旧版本不变。

### 4. 机床禁区基线（按机床复用禁区组合，v1.6）

车间可为一台机床固化一组**已核准的禁区组合**，后续审查按 **机床编号 + 基线版本**
直接引用，不必每次重复列出禁区。

`POST /baselines`

```json
{
  "machine_no": "MC-01",
  "zones": [{"zone_no": 1, "version": 1}, {"zone_no": 2, "version": 3}],
  "description": "已核准的基座+夹具组合"
}
```

- `machine_no`：机床编号（字母数字开头，可含 `_ . : -`，最长 64）；
- `zones`：一组**互不重复**的禁区编号 + **明确版本**；
- 同一机床**首次提交为版本 1**；每次修订（同 `machine_no` 再次提交）产生
  **递增且不可变**的新版本，旧版本永久保留；**并发修订同一机床各获不同版本**，
  不丢失任何已成功提交的版本；
- 响应返回**基线版本与固定禁区清单**（按禁区编号升序）：

```json
{
  "machine_no": "MC-01",
  "version": 1,
  "zones": [{"zone_no": 1, "version": 1}, {"zone_no": 2, "version": 3}],
  "description": "已核准的基座+夹具组合",
  "created_at": "..."
}
```

拒绝策略（**不写入任何基线**）：组内禁区编号重复 `422`；所引禁区或禁区版本
不存在 `404`；机床编号/请求格式非法 `422`。

查询（旧版本永久可查询）：

- `GET /baselines`：全部机床的当前（最大）版本；
- `GET /baselines/{machine_no}`：该机床全部版本；
- `GET /baselines/{machine_no}/versions/{version}`：指定不可变版本的固定禁区清单。

**在审查中引用基线**：单项审查（`POST /reviews`）、批量任务
（`POST /reviews/batch` 的 `items`）与分块上传建会话（`POST /uploads`）均可用
`"baseline": {"machine_no": "MC-01", "version": 1}` **代替原 `zones` 字段**：

```json
{
  "baseline": {"machine_no": "MC-01", "version": 1},
  "start": [-5.0, 5.0, 0.0],
  "tool_radius": 0.5,
  "gcode": "G21 G90 G17\nG1 X15 Y5 Z0\n"
}
```

- `zones` 与 `baseline` **必须且只能提供其一**（同传或都不传均 `422`）；
- 基线不存在 `404`，**不落报告/上传会话**；
- 审查时解析为该基线版本**固化的禁区版本快照**，与直传 `zones` 完全同口径；
  报告继续固化 `used_zone_versions`，`input_summary` 额外记录本次基线引用
  （`"baseline": {"machine_no": ..., "version": ...}`）；
- 分块上传**完成时沿用建会话时的快照**（基线版本不可变，结果一致）；
- 批量任务中任一项基线非法：整批 `422` 逐项错误，**整批不落报告**。

### 5. 提交刀路审查

`POST /reviews`

```json
{
  "zones": [{"zone_no": 1, "version": 1}],
  "start": [-5.0, 5.0, 0.0],
  "tool_radius": 0.5,
  "gcode": "G21 G90 G17\nG1 X15 Y5 Z0\n",
  "include_min_clearance": true,
  "tool_radii": {"1": 0.5, "2": 2.0}
}
```

`include_min_clearance` 可省略（默认 `false`，行为与旧版完全一致），且只接受布尔值
（`true`/`false`，传 `"true"`/`1` 等一律 `422`）。`tool_radii` 可省略（默认不传，单刀模式），
见下文「多刀审查」。`zones` 也可替换为 `"baseline": {"machine_no": ..., "version": ...}`
（机床编号 + 基线版本，二者必须且只能提供其一），见上文「机床禁区基线」。

碰撞响应示例：

```json
{
  "report_id": 1,
  "used_zone_versions": {"1": 1},
  "input_summary": {"gcode_lines": 2, "nonblank_lines": 2, "motion_count": 1,
                    "start_position_mm": [-5.0, 5.0, 0.0],
                    "tool_radius_mm": 0.5,
                    "final_position_mm": [15.0, 5.0, 0.0],
                    "gcode_sha256": "..."},
  "has_collision": true,
  "collision_line_no": 2,
  "collision_zone_no": 1,
  "conclusion": "collision",
  "message": "发现碰撞：G-code 第 2 行与禁区编号 1 冲突"
}
```

无碰撞时 `conclusion` 为 `"no_collision"`，两个碰撞字段为 `null`。G-code 解析错误返回 `422`：

```json
{"detail": {"error": "invalid_gcode", "line_no": 1,
            "message": "第 1 行: 不支持的 G 代码 G54（...）"}}
```

#### 全程最小水平净间隙（可选）

启用后，提交响应与 `GET /reports/{report_id}` 均额外包含：

- `min_clearance_enabled`：该报告是否启用了计算；
- `min_clearance`：结果对象或 `null`（全程不在任何禁区高度内）：

```json
{
  "min_clearance_enabled": true,
  "min_clearance": {
    "min_clearance_mm": 0.5,
    "line_no": 1,
    "point_mm": [0.0, 11.0, 0.0],
    "zone_no": 1,
    "progress": 0.25
  }
}
```

字段含义：

| 字段 | 说明 |
| --- | --- |
| `min_clearance_mm` | 最小**净间隙**（mm）= 连续 XY 路径到填充多边形最小距离 − 刀具半径。刀具外沿恰好接触边界（距离 = 刀半径）时为 `0`；刀尖路径位于填充多边形内部/边界（距离 0）时为负（`-刀半径`） |
| `line_no` | 取得最小值运动段的 **G-code 原行号**；无运动段（按初始刀位）时为 `null` |
| `point_mm` | 取得最小值时的**刀尖坐标** `[x, y, z]`（mm） |
| `zone_no` | 对应**禁区编号** |
| `progress` | 段内进度：直线为线性参数 `t∈[0,1]`，圆弧为弧长进度 `s∈[0,1]`（整圆自起点计） |

口径要点：

- 每段运动只统计刀尖 Z 位于**该禁区**闭合高度范围 `[z_min, z_max]` 内的部分
  （Z 斜进/斜出时按线性插值精确截取窗口，窗口边界本身计入）；
- 直线段按分段二次函数**精确求极值**，圆弧/整圆按弧点-边候选角解析求值；
  不做端点采样；
- 多个候选净间隙相等时，依次按**运动段顺序**、**段内进度**、**禁区编号**取最小；
- 该结果**不改变**首碰撞的结论、行号与禁区编号（二者独立计算）；
- 结果在报告创建时**固化**：后续 `GET /reports/{id}` 反复查询一致，禁区再出新版本不影响旧报告；
- 未启用的请求与升级前已生成的旧报告：`min_clearance_enabled=false`、`min_clearance=null`，
  旧客户端解析不受影响。

### 6. 多刀审查（可选：`tool_radii` 刀号 → 半径映射）

`POST /reviews` 请求可选传入 `"tool_radii"`：**非负整数刀号**到**非负有限毫米半径**的映射，
JSON 键写为十进制整数字符串（如 `"2"`；`"1.5"`、`"-1"`、`"abc"` 均拒绝）。
传入（含空映射 `{}`）即启用多刀模式；**不传**该字段时保持单刀旧行为，`T` 解析后忽略。

```json
{
  "zones": [{"zone_no": 1, "version": 1}],
  "start": [-5.0, 11.0, 0.0],
  "tool_radius": 0.0,
  "tool_radii": {"1": 0.5, "2": 2.0},
  "gcode": "G1 X-2 Y11 Z0\nT2\nG1 X15 Y11 Z0\n",
  "include_min_clearance": true
}
```

语义：

- **初始刀位**仍使用请求里的 `tool_radius`（初始刀的刀号为空）；首个 `Tn` 之前的运动沿用初始刀；
- `Tn` 在**其所在行先于运动生效**：同行运动按新半径检查；随后运动沿用该刀直至下次切换；
- **每次 T 切换**（含与运动同行）都按**新半径**检查切换时的静止刀位
  （静止点也可能因半径变大而碰撞）；同行 T 与运动**分别检查**：
  先按新半径检查换刀点（本行运动前刀位），再检查本行运动；
- 首碰撞与可选全程最小净间隙均按**事件发生时生效刀具的半径**计算；
- 报告对两种命中分别固化 **G-code 原行号、刀号、半径**：
  - 响应/报告新增首碰撞字段 `collision_tool_no`（初始刀位为 `null`）、`collision_tool_radius_mm`；
  - `min_clearance` 对象在多刀模式下新增 `tool_no`（初始刀位为 `null`）、`tool_radius_mm`；
  - 单刀模式与旧报告：首碰撞两字段为 `null`，`min_clearance` 中**不出现**这两个键；
- 等值裁决：先按**执行顺序**（初始刀位 → 各静止换刀/运动事件），再按既有**段内进度**、
  **禁区编号**；
- `input_summary` 在多刀模式下额外固化 `tool_map_enabled: true` 与 `tool_radii_mm` 快照。

多刀模式下以下输入一律 `422`（错误体为 `invalid_gcode`，携带原行号），且**不生成报告**：

- `T` 非整数或负数（如 `T1.5`、`T-1`）；
- 同一行出现多个 `T`（如 `T1 T2`）；
- `T` 刀号未在 `tool_radii` 中映射（空映射时任何 `T` 都拒绝）；
- 映射本身非法：刀号非非负整数、半径为负/非有限/非数值（如 `"1": -0.5`、`"x": 1`）。

### 7. 执行事件轨迹（多刀模式随报告固化）

多刀模式（传入 `tool_radii`）下，提交响应与 `GET /reports/{report_id}` 均包含
`execution_trace`：**按执行顺序**记录的可回看事件轨迹——

1. **初始刀位**（`kind="initial"`，`seq=0`，行号与刀号为 `null`，半径为 `tool_radius`）；
2. **每次 T 切换时的静止刀位**（`kind="tool_change"`，含与运动同行的 T：
   位置为本行运动前刀位，起止坐标相同，执行顺序**先于**本行运动）；
3. **每段运动**（`kind="motion"`，含起止刀尖坐标）。

```json
[
  {"seq": 0, "kind": "initial", "line_no": null, "tool_no": null,
   "tool_radius_mm": 0.0, "start_mm": [-5.0, 11.0, 0.0], "end_mm": [-5.0, 11.0, 0.0],
   "hit_zone_no": null},
  {"seq": 1, "kind": "motion", "line_no": 1, "tool_no": null,
   "tool_radius_mm": 0.0, "start_mm": [-5.0, 11.0, 0.0], "end_mm": [-2.0, 11.0, 0.0],
   "hit_zone_no": null},
  {"seq": 2, "kind": "tool_change", "line_no": 2, "tool_no": 2,
   "tool_radius_mm": 2.0, "start_mm": [-2.0, 11.0, 0.0], "end_mm": [-2.0, 11.0, 0.0],
   "hit_zone_no": null},
  {"seq": 3, "kind": "motion", "line_no": 3, "tool_no": 2,
   "tool_radius_mm": 2.0, "start_mm": [-2.0, 11.0, 0.0], "end_mm": [15.0, 11.0, 0.0],
   "hit_zone_no": 1}
]
```

每项字段：

| 字段 | 说明 |
| --- | --- |
| `seq` | 执行顺序（初始刀位为 0，其余从 1 起递增；同行 T 的换刀事件先于本行运动） |
| `kind` | `initial` / `tool_change` / `motion` |
| `line_no` | G-code **原行号**；初始刀位为 `null` |
| `tool_no` | 该事件生效**刀号**；初始刀位为 `null` |
| `tool_radius_mm` | 该事件生效刀具**半径**（mm） |
| `start_mm` / `end_mm` | 事件起止刀尖坐标 `[x, y, z]`（mm）；静止事件（初始刀位/换刀）起止相同 |
| `hit_zone_no` | 该事件**命中的禁区编号**（运动段内多禁区取最早命中），未命中为 `null` |

口径要点：

- 同行 T 与运动**分别记录**：先按新半径检查换刀点（`tool_change`），再检查运动（`motion`）；
- **首碰撞对应轨迹中首个 `hit_zone_no` 非空的事件**（其行号/刀号/半径即
  `collision_line_no` / `collision_tool_no` / `collision_tool_radius_mm`）；
- 可选**最小净间隙沿同一事件顺序**裁决（等值先执行顺序，再段内进度、禁区编号）；
- 轨迹在报告创建时**固化**：后续 `GET /reports/{id}` 反复查询一致，
  禁区再出新版本不影响旧报告轨迹；
- **单刀请求**（未传 `tool_radii`）与**升级前的旧报告**：`execution_trace` 为 `null`，
  旧客户端解析不受影响；
- 非法 `T` 仍按原规则 `422` 拒绝且**不留任何报告**（自然也不产生轨迹）。

### 8. 批量审查（一次提交 1～50 项有序任务，`batch_id` 幂等）

`POST /reviews/batch`

```json
{
  "batch_id": "B-20261006-001",
  "items": [
    {"task_id": "pocket-1",
     "zones": [{"zone_no": 1, "version": 1}],
     "start": [-5, 5, 0], "tool_radius": 0.5,
     "gcode": "G21 G90 G17\nG1 X15 Y5 Z0\n",
     "include_min_clearance": true},
    {"task_id": "drill-2",
     "zones": [{"zone_no": 1, "version": 1}],
     "start": [-5, 11, 0], "tool_radius": 0.0,
     "tool_radii": {"2": 2.0},
     "gcode": "G1 X-2 Y11 Z0\nT2\nG1 X15 Y11 Z0\n"}
  ]
}
```

- `batch_id`：批次幂等键，必填；字母数字开头，可含 `_ . : -`，最长 64。
- `items`：**1～50 项**有序任务；每项为完整的单项审查输入（同 `POST /reviews`），
  可另带可选 `task_id`（批内唯一，校验规则同 `batch_id`；省略时按输入顺序号标识）。
  每项独立使用最小净间隙与多刀参数，任务之间互不影响。
- **同一事务**：先逐项校验并固定各项引用的禁区版本快照，全部通过才按**输入顺序**
  生成不可变报告并统一提交；任一项几何、G-code、参数或任务标识非法时，
  返回 `422` 与**逐项错误**（`failed_items` 仅列失败项，含 `index`/`task_id`/`error`），
  **整批不生成任何报告**，且该 `batch_id` 不被占用（修正后可同名重提）：

```json
{
  "error": "invalid_batch",
  "batch_id": "B-20261006-001",
  "message": "批量审查未通过：1 项非法，整批未生成任何报告",
  "failed_items": [
    {"index": 1, "task_id": "drill-2",
     "error": {"error": "invalid_gcode", "line_no": 2, "message": "第 2 行: ..."}}
  ]
}
```

- 全部通过返回 `201`，逐项给出输入顺序号、任务标识与完整单项审查结果
  （含 `report_id`，可继续 `GET /reports/{report_id}` 回看）：

```json
{
  "batch_id": "B-20261006-001",
  "item_count": 2,
  "results": [
    {"index": 0, "task_id": "pocket-1",
     "result": {"report_id": 11, "conclusion": "collision",
                "has_collision": true, "collision_line_no": 2,
                "collision_zone_no": 1, "...": "..."}},
    {"index": 1, "task_id": "drill-2",
     "result": {"report_id": 12, "conclusion": "no_collision", "...": "..."}}
  ]
}
```

- **幂等重放**：相同 `batch_id` + 相同内容再次提交返回 `200` 与**首次逐项结果**
  （`report_id` 不变，不生成新报告）；相同 `batch_id` + 不同内容返回 `409`
  （`batch_conflict`）且不生成新报告。内容按逐项规范化请求计算 SHA-256 判定；
  并发同 `batch_id` 由数据库唯一约束兜底，结果一致。

### 9. 长 G-code 可恢复分块上传（`/uploads`，v1.5）

车间网络不稳时，长 G-code 不必一次性提交：先建会话冻结审查参数，再分块乱序上传，
断网恢复后按已收序号续传，最后声明块数与整文摘要完成审查。
全部状态落库（`upload_sessions` / `upload_chunks`），**跨服务重启保留**。

#### 9.1 创建上传会话

`POST /uploads`

请求体与 `POST /reviews` 相同但**不含 `gcode`**（禁区编号 + 明确版本、初始刀尖坐标、
刀半径、可选 `include_min_clearance` / `tool_radii`，校验口径一致）：

```json
{
  "zones": [{"zone_no": 1, "version": 1}],
  "start": [-5.0, 5.0, 0.0],
  "tool_radius": 0.5,
  "include_min_clearance": true,
  "tool_radii": {"2": 2.0}
}
```

创建时即校验禁区编号与明确版本存在（404/422 同 `/reviews`），参数**冻结**随会话落库
（随后禁区再出新版本不影响本会话，完成时仍按固定的明确版本审查）。
返回 `201` 与会话标识及上限：

```json
{
  "session_id": "7ace31c6448f48e4afc2de15b12aed19",
  "status": "open",
  "params": {"zones": [{"zone_no": 1, "version": 1}], "...": "..."},
  "received_seqs": [],
  "received_count": 0,
  "total_bytes": 0,
  "max_chunk_bytes": 65536,
  "max_total_bytes": 8388608,
  "declared_chunk_count": null,
  "declared_sha256": null,
  "report_id": null,
  "created_at": "...", "completed_at": null
}
```

#### 9.2 提交文本块（0 起序号，可乱序）

`PUT /uploads/{session_id}/chunks/{seq}`

- 请求体为**原始 UTF-8 文本块**（`Content-Type` 不限，建议 `text/plain; charset=utf-8`
  或 `application/octet-stream`）；块边界可以切在任意字符边界（含行中间），
  行号最终按**拼接后的原文**计算；
- `seq` 为 **0 起的整数**（上界 8388607）；块可**乱序**到达；
- **单块 1 字节～64 KiB**（空块 `422 empty_chunk`，超限 `413 chunk_too_large`）；
  **会话总量 ≤ 8 MiB**（超限 `413 total_size_exceeded`，该块不入库）；
- 非 UTF-8 内容 `422 invalid_encoding`；
- 新块入库返回 `201` 回执；**同号同内容重传**返回 `200` 与**原回执**（幂等，
  计数不重复）；**同号异内容**返回 `409 chunk_conflict` 且**不覆盖**原块：

```json
{"session_id": "...", "seq": 1, "byte_len": 5,
 "sha256": "6f1febdda7724a284d20ad4d8aae10a06668013b9eaeebe98608d9945ef6e427"}
```

#### 9.3 查询会话与已收序号

`GET /uploads/{session_id}`

返回 9.1 同形状态：`received_seqs`（已收序号升序，断点续传依据）、
`received_count` / `total_bytes`、完成后的 `declared_chunk_count` /
`declared_sha256` / `report_id` 等。

#### 9.4 完成上传（声明块数 + 整文 SHA-256）

`POST /uploads/{session_id}/complete`

```json
{"chunk_count": 3,
 "sha256": "c80c5d4af928519d2166d01d80de689bae4a65f484ac306837404f53adef553f"}
```

- `chunk_count` 为**正整数**（≤ 8388608）；`sha256` 为**拼接后文本**（块 0..块数-1
  按序拼接的 UTF-8 字节）的 SHA-256，64 位 hex（大小写均可）；
- **仅在** 0..块数-1 齐全、无越界块（序号 ≥ 块数的已上传块）、摘要一致、
  且整份 G-code 通过既有审查校验时，按与 `POST /reviews` **完全相同的口径**
  生成一份不可变报告，返回 `201` 与完整审查结果（含 `report_id`，
  可继续 `GET /reports/{report_id}` 回看）；
- **相同完成声明**（块数 + 摘要均一致）并发或重放返回 `200` 与**同一报告**
  （响应与首次一致，不生成新报告）；成功完成后**不同声明**返回
  `409 completion_conflict`，**新块**返回 `409 session_completed`
  （同号同内容重传仍返回原回执）；
- 以下失败均**不留报告**、会话保持 `open`（可修正后重新完成）：

| 情形 | 状态码 | `detail.error` |
| --- | --- | --- |
| 缺块（0..块数-1 未齐全） | 409 | `incomplete_upload`（含 `missing_seqs`/`missing_count`） |
| 存在序号 ≥ 块数的越界块 | 409 | `unexpected_chunks`（含 `extra_seqs`/`extra_count`） |
| 拼接文本摘要与声明不符 | 409 | `digest_mismatch`（含实际摘要） |
| G-code 解析/参数非法 | 422 | 与 `/reviews` 同形（如 `invalid_gcode`，含行号） |
| 块数/摘要格式非法 | 422 | 请求校验错误 |

#### 9.5 完整流程示例

```bash
# 1) 创建会话（冻结审查参数）
SID=$(curl -s -X POST http://localhost:8080/uploads \
  -H 'Content-Type: application/json' \
  -d '{"zones":[{"zone_no":1,"version":1}],"start":[-5,5,0],
       "tool_radius":0.5,"include_min_clearance":true}' \
  | sed -n 's/.*"session_id":"\([0-9a-f]*\)".*/\1/p')

# 2) 乱序分块上传（断网后重传同号块安全幂等）
printf 'G21 G90 G17\n' | curl -s -X PUT "http://localhost:8080/uploads/$SID/chunks/0" --data-binary @-
printf 'G1 X1'         | curl -s -X PUT "http://localhost:8080/uploads/$SID/chunks/1" --data-binary @-
printf '5 Y5 Z0\n'     | curl -s -X PUT "http://localhost:8080/uploads/$SID/chunks/2" --data-binary @-

# 3) 查询已收序号，确认齐全后完成
curl -s "http://localhost:8080/uploads/$SID"
DIGEST=$(printf 'G21 G90 G17\nG1 X15 Y5 Z0\n' | sha256sum | cut -d' ' -f1)
curl -s -X POST "http://localhost:8080/uploads/$SID/complete" \
  -H 'Content-Type: application/json' \
  -d "{\"chunk_count\": 3, \"sha256\": \"$DIGEST\"}"
```

### 10. 查询报告（不可变）

`GET /reports/{report_id}`

### 11. 工单刀路审查放行（`/releases`，v1.7）

车间按**工单**为一台机床的一组**有序、已完成的无碰撞报告**办理审查放行。
放行一次成功即**固化**：后续基线再修订、禁区再出新版，该工单的放行结果都不变。

`POST /releases`

```json
{
  "work_order_no": "WO-20261007-001",
  "machine_no": "MC-01",
  "expected_version": 2,
  "report_ids": [102, 101, 105]
}
```

- `work_order_no`：工单号（字母数字开头，可含 `_ . : -`，最长 64），**幂等键**；
- `machine_no` / `expected_version`：要锁定的机床编号与**预期基线版本**；
- `report_ids`：**1～50 个**有序报告编号，**不得重复**（顺序按请求原样固化，
  不按编号排序，同一份报告也不能在同一工单中出现两次）。

**放行条件（全部满足才固化，任一不满足拒绝且不留部分记录）：**

1. 该机床存在 `expected_version` 基线版本（不存在 `404 baseline_not_found`）；
2. `expected_version` 仍是该机床**当前（最大）版本**
   （已过期 `409 baseline_version_stale`，返回 `current_version`）；
3. 全部报告存在（缺失 `404 release_report_not_found`，给出缺失编号）；
4. 全部报告**无碰撞**（任一碰撞 `422 release_report_has_collision`，
   给出顺序位 `index`、报告编号、碰撞行/禁区）；
5. 每份报告固化的基线引用
   （`input_summary.baseline = {machine_no, version}`）与请求机床、版本一致
   （不一致 `422 release_report_baseline_mismatch`）；因此**直传 `zones`
   审查出的报告不能放行**，报告必须是用该机床基线审查生成的；
6. 每份报告固化的 `used_zone_versions` 与该基线版本固化的禁区清单
   **完全一致**（编号集合与各编号版本均相同，不一致
   `422 release_report_zone_versions_mismatch`）。

**并发一致性**：基线修订（`POST /baselines`）与工单放行在同一机床的串行锁
（`machine_locks`）内互斥推进——放行事务在锁内完成「当前版本确认 + 全部校验
+ 固化」，期间基线无法插入新版本，因此**判定与记录必然对应同一版本状态**；
修订完成后再到达的放行只能看到新版本，按过期拒绝。

成功响应 `201`（按输入顺序固化报告摘要与放行时间）：

```json
{
  "work_order_no": "WO-20261007-001",
  "machine_no": "MC-01",
  "baseline_version": 2,
  "machine_current_version": 2,
  "report_ids": [102, 101, 105],
  "report_count": 3,
  "reports": [
    {"index": 0, "report_id": 102, "has_collision": false,
     "used_zone_versions": {"1": 3, "2": 1}},
    {"index": 1, "report_id": 101, "has_collision": false,
     "used_zone_versions": {"1": 3, "2": 1}},
    {"index": 2, "report_id": 105, "has_collision": false,
     "used_zone_versions": {"1": 3, "2": 1}}
  ],
  "released_at": "2026-10-07T02:40:00Z"
}
```

**幂等与冲突（工单号维度）：**

- 相同 `work_order_no` + **相同内容**（机床、预期版本、有序报告编号完全一致）
  重试：返回 `200` 与**首次放行结果逐字段一致的快照**——即使期间基线已修订、
  版本已过期，重试也**不受后续基线修订影响**；
- 相同 `work_order_no` + **不同内容**（改机床/版本/报告集合或顺序）：`409
  release_conflict`，不新增记录、不改动原放行；
- 并发提交同一工单相同内容：唯一约束兜底，一个 `201` 其余重放 `200`，只落一条。

查询：

- `GET /releases/{work_order_no}`：返回该工单**固化的放行快照**（内容不随后续
  基线/禁区修订改变）；从未放行的工单 `404 release_not_found`；
- `GET /releases`：全部工单放行概览（工单号、机床、固化基线版本、报告数、
  放行时间，按放行时间升序）。

> 状态码约定：`422` 请求格式/报告不合格（含编号重复/越界、碰撞报告、基线引用
> 或禁区版本不一致）；`404` 基线版本或报告不存在；`409` 版本过期或同工单
> 异内容冲突。任何失败都不会产生工单记录或部分固化。

## 命令行调用示例

另见 `examples/curl_examples.sh` 与 `examples/python_client.py`。

```bash
# 登记禁区
curl -s -X POST http://localhost:8080/zones \
  -H 'Content-Type: application/json' \
  -d '{"zone_no":1,"polygon":[[0,0],[10,0],[10,10],[0,10]],"z_min":-5,"z_max":5}'

# 提交审查
curl -s -X POST http://localhost:8080/reviews \
  -H 'Content-Type: application/json' \
  -d '{"zones":[{"zone_no":1,"version":1}],"start":[-5,5,0],
       "tool_radius":0.5,"gcode":"G21 G90 G17\nG1 X15 Y5 Z0\n"}'

# 多刀审查：初始刀半径 0，T2 换 r=2 的刀后横穿（碰撞行固化刀号/半径）
curl -s -X POST http://localhost:8080/reviews \
  -H 'Content-Type: application/json' \
  -d '{"zones":[{"zone_no":1,"version":1}],"start":[-5,11,0],
       "tool_radius":0.0,"tool_radii":{"2":2.0},
       "gcode":"G1 X-2 Y11 Z0\nT2\nG1 X15 Y11 Z0\n"}'

# 多刀执行事件轨迹：同行 T 与运动分别记录，先查换刀点再查运动；
# execution_trace 随报告固化，GET /reports/{id} 可反复回看
curl -s -X POST http://localhost:8080/reviews \
  -H 'Content-Type: application/json' \
  -d '{"zones":[{"zone_no":1,"version":1}],"start":[0,11,0],
       "tool_radius":0.0,"tool_radii":{"1":2.0},
       "gcode":"T1 G1 X5 Y11 Z0\n"}'
# 响应 execution_trace 依次为 initial / tool_change（命中）/ motion（命中），
# 首碰撞即首个命中事件（第 1 行换刀点，刀号 1）

# 机床禁区基线：按机床编号固化一组禁区编号+明确版本（首版为 1）
curl -s -X POST http://localhost:8080/baselines \
  -H 'Content-Type: application/json' \
  -d '{"machine_no":"MC-01","zones":[{"zone_no":1,"version":1}],
       "description":"已核准的基座组合"}'

# 用 机床编号+基线版本 代替 zones 提交审查（与直传 zones 同口径）
curl -s -X POST http://localhost:8080/reviews \
  -H 'Content-Type: application/json' \
  -d '{"baseline":{"machine_no":"MC-01","version":1},"start":[-5,5,0],
       "tool_radius":0.5,"gcode":"G21 G90 G17\nG1 X15 Y5 Z0\n"}'

# 修订基线 => 递增不可变新版本；旧版仍可查询
curl -s -X POST http://localhost:8080/baselines \
  -H 'Content-Type: application/json' \
  -d '{"machine_no":"MC-01","zones":[{"zone_no":1,"version":2}]}'
curl -s http://localhost:8080/baselines/MC-01

# 工单刀路审查放行：工单号 + 机床 + 预期基线版本 + 1～50 个有序无碰撞报告
# （报告须以同一机床同一基线版本审查生成；预期版本必须仍是当前版本）
curl -s -X POST http://localhost:8080/releases \
  -H 'Content-Type: application/json' \
  -d '{"work_order_no":"WO-20261007-001","machine_no":"MC-01",
       "expected_version":1,"report_ids":[2,1]}'
# 同工单同内容重试 => 200 + 首次固化结果（基线后续修订也不受影响）；
# 异内容 => 409 release_conflict；版本过期 => 409 baseline_version_stale
curl -s http://localhost:8080/releases/WO-20261007-001   # 固化快照查询
curl -s http://localhost:8080/releases                   # 全部放行概览
```

## G-code 支持范围与拒绝策略

| 代码 | 含义 | 处理 |
| --- | --- | --- |
| `G0` / `G1` | 快速 / 直线插补（X/Y/Z） | 检查连续运动，Z 变化时按高度区间精确求交 |
| `G2` / `G3` | 顺 / 逆圆弧，`I/J` 相对弧起点 | 仅 G17 XY、恒定 Z；半径不一致、I=J=0 等拒绝；同起终点为整圆 |
| `G17` | XY 平面 | 默认；`G18/G19` 拒绝 |
| `G20` / `G21` | 英寸 / 毫米 | 默认 G21；G20 数值自动换算毫米 |
| `G90` / `G91` | 绝对 / 增量 | 默认 G90 |
| 其他 G | `G52`–`G59`、固定循环（如 `G81`）、`G28` 等 | **明确拒绝（422）** |
| `R` 圆弧半径格式 | — | **明确拒绝（422）**，仅接受 I/J |
| `F/S/N/M` 等 | 进给/转速/行号/辅助功能 | 解析后忽略，不参与几何 |
| `T` | 刀号 | **单刀模式**（未传 `tool_radii`）：解析后忽略；**多刀模式**：非负整数、同行至多一个且必须已映射，`Tn` 先于本行运动生效；每次 T 切换（含同行）都按新半径检查切换时静止刀位并记入执行事件轨迹 |

支持分号行注释与圆括号注释（括号不平衡将拒绝）；`%` 程序标记忽略；地址字大小写不敏感；
行号报告使用**原始物理行号（从 1 开始）**。

## 项目结构

```
app/
  main.py        # FastAPI 路由：禁区/版本/机床基线/审查/批量审查/分块上传/
                 # 工单放行/报告（基线修订与工单放行共用机床串行锁）
  schemas.py     # 请求响应模型与输入校验（含执行事件轨迹、批量输出、分块上传、
                 # 机床基线与工单放行）
  models.py      # zones / zone_versions / zone_baselines / reports / batches
                 # / upload_sessions / upload_chunks / machine_locks
                 # / work_order_releases 表
  database.py    # 引擎与会话
  gcode.py       # G-code 词法/模态解析（含多刀 T 切换与静止换刀事件）
  geometry.py    # 多边形校验、点/线段/圆弧距离、弧-多边形最近点
  collision.py   # 连续运动碰撞引擎（精确区间求解 + 圆弧二分）+ 全程最小净间隙
                 # + 多刀执行事件轨迹（按执行顺序检查）
examples/        # curl 与 Python 调用示例
tests/test_audit.py
Dockerfile
docker-compose.yml
```

## 测试

```bash
pip install httpx
python -m unittest tests.test_audit -v
```

测试使用 SQLite 内存文件覆盖数据库，共覆盖几何校验、线段/圆弧碰撞、模态解析、
版本不可变、旧报告不变、非法输入不落报告、可选全程最小净间隙（直线/圆弧/整圆/
Z 窗口截取/边界接触为零/负值/无运动段/等值裁决/固化与兼容），多刀半径映射
（同行/独立 T 生效、模态延续、初始刀位空刀号、静止换刀命中、按事件半径计算首碰撞与净间隙、
等值执行顺序裁决、非法 T/非法映射 422 不落报告、旧库列迁移与单刀兼容），
多刀执行事件轨迹（同行 T 与运动分别记录且换刀点先查、轨迹顺序与字段、
首碰撞对应首个命中事件、最小净间隙沿同一顺序裁决、轨迹随报告固化且不受禁区新版本影响、
单刀请求与旧报告为 null），批量审查（有序逐项结果与报告编号、各项独立引用版本快照、
任一项非法 422 逐项错误且整批不落报告、失败批次不占用 batch_id、任务/批次标识校验、
1～50 项边界、相同 batch_id 重放返回首次结果、不同内容 409 冲突且不生成新报告），
以及分块上传（会话冻结审查参数与明确版本、乱序块与行中间切块、同号同内容幂等回执/
同号异内容 409、空块/非 UTF-8/单块 64 KiB/总量 8 MiB 上限、缺块/越界块/摘要不符/
解析失败均不留报告且会话保持 open、完成与单项审查口径一致、相同声明重放与并发返回
同一报告、完成后不同声明冲突且拒绝新块、旧库启动幂等建新表），
以及机床禁区基线（首版为 1、修订递增不可变且旧版可查询、组内编号重复/禁区或版本
不存在拒绝且不写入、审查以 机床编号+基线版本 解析快照并与直传 zones 同口径、
基线快照不可变、zones 与 baseline 同传或均缺 422、基线不存在 404 且不落报告、
批量项混用 baseline 与 zones 且任一项非法整批不落报告、分块上传建会话用 baseline
且完成沿用快照、并发修订各获不同版本不丢失），
以及工单刀路审查放行（首次放行固化工单/报告顺序/基线版本/放行时间、
按工单查询不随后续修订改变、同内容重放返回首次快照且不受后续修订影响、
异内容 409 冲突、预期版本过期 409、基线版本/报告不存在 404、
碰撞报告/基线引用不一致/固化禁区版本与基线清单不一致 422、
编号重复/越界/数量边界 422、任何失败不留部分记录、
基线修订与放行并发按同一版本状态串行判定、同工单并发单一胜者）等场景。
