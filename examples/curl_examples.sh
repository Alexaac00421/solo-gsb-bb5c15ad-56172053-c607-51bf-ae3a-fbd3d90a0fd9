#!/usr/bin/env bash
# 数控刀路禁入区审查服务调用示例
# 用法: bash examples/curl_examples.sh
set -euo pipefail

BASE="${BASE:-http://localhost:8080}"

echo "== 健康检查 =="
curl -s "$BASE/health"; echo

echo "== 1) 登记禁区 1：10x10 mm 方块，Z 闭合范围 [-5, 5] =="
curl -s -X POST "$BASE/zones" \
  -H 'Content-Type: application/json' \
  -d '{
        "zone_no": 1,
        "polygon": [[0,0],[10,0],[10,10],[0,10]],
        "z_min": -5,
        "z_max": 5,
        "description": "基座（毫米）"
      }'; echo

echo "== 2) 查看禁区及版本 =="
curl -s "$BASE/zones/1"; echo

echo "== 3) 提交审查：横穿禁区（应当碰撞，首个碰撞在第 2 行） =="
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 5, 0],
        "tool_radius": 0.0,
        "gcode": "G21 G90 G17\nG1 X15 Y5 Z0\n"
      }'; echo

echo "== 4) 提交审查：从禁区上方经过（无碰撞） =="
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 50, 0],
        "tool_radius": 0.0,
        "gcode": "G1 X15 Y50 Z0\n"
      }'; echo

echo "== 5) 非法指令（G54 坐标系）必须被拒绝，且不产生报告 =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [0,0,0],
        "tool_radius": 0.0,
        "gcode": "G54 G1 X1\n"
      }'

echo "== 6) 登记禁区新版本（几何平移到远处），旧版本保持不变 =="
curl -s -X POST "$BASE/zones/1/versions" \
  -H 'Content-Type: application/json' \
  -d '{
        "polygon": [[100,100],[110,100],[110,110],[100,110]],
        "z_min": -5,
        "z_max": 5
      }'; echo

echo "== 7) 同一刀路按新版本审查（无碰撞） =="
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 2}],
        "start": [-5, 5, 0],
        "tool_radius": 0.0,
        "gcode": "G1 X15 Y5 Z0\n"
      }'; echo

echo "== 8) 旧报告内容不随后续禁区更新改变 =="
curl -s "$BASE/reports/1"; echo

echo "== 9) 可选：启用全程最小水平净间隙计算（include_min_clearance=true） =="
# 先把禁区恢复为版本 1 风格（如已执行第 6 步，可显式引用 v1）；
# 路径 y=11 与方块边 y=10 距离 1mm，刀半径 0.5 => 最小净间隙 0.5mm
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 11, 0],
        "tool_radius": 0.5,
        "gcode": "G1 X15 Y11 Z0\n",
        "include_min_clearance": true
      }'; echo

echo "== 10) 未启用最小净间隙的请求：min_clearance 为 null，旧调用完全兼容 =="
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 11, 0],
        "tool_radius": 0.5,
        "gcode": "G1 X15 Y11 Z0\n"
      }'; echo

echo "== 11) 多刀半径映射（tool_radii）：T2 先于本行运动生效 =="
# 初始刀半径 tool_radius=0，首段停在安全区 (-2,11)（距方块角 sqrt(5)mm）；
# 独立 T2 行换刀 r=2（静止刀位仍安全）；随后 y=11 横穿，最近距离 1mm < 2 => 碰撞，
# 报告固化首碰撞行号 3、刀号 2、半径 2
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 11, 0],
        "tool_radius": 0.0,
        "tool_radii": {"2": 2.0},
        "gcode": "G1 X-2 Y11 Z0\nT2\nG1 X15 Y11 Z0\n",
        "include_min_clearance": true
      }'; echo

echo "== 12) T 可与运动同行（新半径作用于本行运动）；换回小刀后不再碰撞 =="
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 50, 0],
        "tool_radius": 2.0,
        "tool_radii": {"1": 0.5},
        "gcode": "T1 G1 X-5 Y50\nG1 X15 Y11 Z0\n"
      }'; echo

echo "== 13) 多刀模式非法输入一律 422：非整数/负数/同行多个 T/未映射刀号/非法半径 =="
for body in \
  '{"zones":[{"zone_no":1,"version":1}],"start":[0,0,0],"tool_radius":0.0,"gcode":"T1.5\n","tool_radii":{"1":1}}' \
  '{"zones":[{"zone_no":1,"version":1}],"start":[0,0,0],"tool_radius":0.0,"gcode":"T9\n","tool_radii":{"1":1}}' \
  '{"zones":[{"zone_no":1,"version":1}],"start":[0,0,0],"tool_radius":0.0,"gcode":"T1\n","tool_radii":{"-1":1}}' \
  '{"zones":[{"zone_no":1,"version":1}],"start":[0,0,0],"tool_radius":0.0,"gcode":"T1\n","tool_radii":{"1":-0.5}}'; do
  curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE/reviews" \
    -H 'Content-Type: application/json' -d "$body"
done

echo "== 14) 多刀执行事件轨迹（execution_trace）：同行 T 与运动分别记录 =="
# 同行 T1 换 r=2 的刀：轨迹依次记录 初始刀位 -> 换刀点（静止，先按新半径检查）
# -> 本行运动；换刀点 (0,11) 距方块边 1mm < 2 => tool_change 事件即首个命中，
# 首碰撞行号 1、刀号 1；轨迹随报告固化，GET /reports/{id} 反复查询一致
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [0, 11, 0],
        "tool_radius": 0.0,
        "tool_radii": {"1": 2.0},
        "gcode": "T1 G1 X5 Y11 Z0\n"
      }'; echo

echo "== 15) 回看上一次多刀报告的固化轨迹（不受禁区新版本影响） =="
LAST_REPORT=$(curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 11, 0],
        "tool_radius": 0.0,
        "tool_radii": {"2": 2.0},
        "gcode": "G1 X-2 Y11 Z0\nT2\nG1 X15 Y11 Z0\n"
      }' | sed -n 's/.*"report_id":\([0-9]*\).*/\1/p')
curl -s "$BASE/reports/$LAST_REPORT"; echo

echo "== 16) 批量审查：一次提交 3 项有序任务（同一事务，batch_id 幂等） =="
# 每项独立给出禁区版本/初始刀尖/刀半径/G-code，可带可选 task_id 与
# 最小净间隙、多刀参数；全部通过才按输入顺序生成报告（201）
curl -s -X POST "$BASE/reviews/batch" \
  -H 'Content-Type: application/json' \
  -d '{
        "batch_id": "B-20261006-001",
        "items": [
          {"task_id": "hit-v1",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 5, 0], "tool_radius": 0.5,
           "gcode": "G21 G90 G17\nG1 X15 Y5 Z0\n",
           "include_min_clearance": true},
          {"task_id": "safe-high",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 50, 0], "tool_radius": 0.0,
           "gcode": "G1 X15 Y50 Z0\n"},
          {"task_id": "multi-tool",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 11, 0], "tool_radius": 0.0,
           "tool_radii": {"2": 2.0},
           "gcode": "G1 X-2 Y11 Z0\nT2\nG1 X15 Y11 Z0\n"}
        ]
      }'; echo

echo "== 17) 相同 batch_id + 相同内容重放：返回首次逐项结果（200，不生成新报告） =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE/reviews/batch" \
  -H 'Content-Type: application/json' \
  -d '{
        "batch_id": "B-20261006-001",
        "items": [
          {"task_id": "hit-v1",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 5, 0], "tool_radius": 0.5,
           "gcode": "G21 G90 G17\nG1 X15 Y5 Z0\n",
           "include_min_clearance": true},
          {"task_id": "safe-high",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 50, 0], "tool_radius": 0.0,
           "gcode": "G1 X15 Y50 Z0\n"},
          {"task_id": "multi-tool",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 11, 0], "tool_radius": 0.0,
           "tool_radii": {"2": 2.0},
           "gcode": "G1 X-2 Y11 Z0\nT2\nG1 X15 Y11 Z0\n"}
        ]
      }'

echo "== 18) 相同 batch_id + 不同内容：409 冲突，不生成新报告 =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE/reviews/batch" \
  -H 'Content-Type: application/json' \
  -d '{
        "batch_id": "B-20261006-001",
        "items": [
          {"zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 50, 0], "tool_radius": 0.0,
           "gcode": "G1 X15 Y50 Z0\n"}
        ]
      }'

echo "== 19) 任一项非法：422 逐项错误，整批不生成任何报告 =="
# 第 2 项 G-code 非法、第 3 项禁区不存在：failed_items 逐项列出，
# 其余合法项也不会落报告；失败的 batch_id 不占用，修正后可同名重提
curl -s -X POST "$BASE/reviews/batch" \
  -H 'Content-Type: application/json' \
  -d '{
        "batch_id": "B-20261006-002",
        "items": [
          {"task_id": "ok",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [-5, 50, 0], "tool_radius": 0.0,
           "gcode": "G1 X15 Y50 Z0\n"},
          {"task_id": "bad-gcode",
           "zones": [{"zone_no": 1, "version": 1}],
           "start": [0, 0, 0], "tool_radius": 0.0,
           "gcode": "G54 G1 X1\n"},
          {"task_id": "bad-zone",
           "zones": [{"zone_no": 999, "version": 1}],
           "start": [0, 0, 0], "tool_radius": 0.0,
           "gcode": "G1 X1\n"}
        ]
      }'; echo

echo "== 20) 分块上传：创建会话（冻结禁区版本/初始刀尖/刀半径/可选设置） =="
# 车间网络不稳时的可恢复提交：先建会话拿到 session_id，
# 审查参数（禁区编号+明确版本、初始刀尖、刀半径、可选多刀/最小净间隙）
# 在创建时固定，随后只需分块上传 G-code 文本
SID=$(curl -s -X POST "$BASE/uploads" \
  -H 'Content-Type: application/json' \
  -d '{
        "zones": [{"zone_no": 1, "version": 1}],
        "start": [-5, 5, 0],
        "tool_radius": 0.5,
        "include_min_clearance": true
      }' | sed -n 's/.*"session_id":"\([0-9a-f]*\)".*/\1/p')
echo "session_id: $SID"

echo "== 21) 乱序提交 UTF-8 文本块（单块 <= 64 KiB，总量 <= 8 MiB） =="
# 完整文本为 "G21 G90 G17\nG1 X15 Y5 Z0\n"，切成 3 块乱序上传；
# 块体为原始文本（Content-Type 不限），回执含块序号/字节数/SHA-256
printf 'G21 G90 G17\n' | curl -s -X PUT "$BASE/uploads/$SID/chunks/0" --data-binary @-; echo
printf '5 Y5 Z0\n'     | curl -s -X PUT "$BASE/uploads/$SID/chunks/2" --data-binary @-; echo
printf 'G1 X1'         | curl -s -X PUT "$BASE/uploads/$SID/chunks/1" --data-binary @-; echo

echo "== 22) 断网重传：同号同内容返回原回执（200），同号异内容 409 不覆盖 =="
printf 'G1 X1' | curl -s -X PUT "$BASE/uploads/$SID/chunks/1" --data-binary @-; echo
printf 'G1 X9' | curl -s -o /dev/null -w "HTTP %{http_code}\n" -X PUT "$BASE/uploads/$SID/chunks/1" --data-binary @-

echo "== 23) 查询已收序号（断点续传依据） =="
curl -s "$BASE/uploads/$SID"; echo

echo "== 24) 完成：声明块数与拼接文本 SHA-256 => 生成不可变报告（201） =="
# 仅当 0..块数-1 齐全、无越界块、摘要一致且 G-code 通过审查校验才生成报告；
# 行号按拼接后的原文计算，结果与 POST /reviews 同口径
DIGEST=$(printf 'G21 G90 G17\nG1 X15 Y5 Z0\n' | sha256sum | cut -d' ' -f1)
curl -s -X POST "$BASE/uploads/$SID/complete" \
  -H 'Content-Type: application/json' \
  -d "{\"chunk_count\": 3, \"sha256\": \"$DIGEST\"}"; echo

echo "== 25) 相同完成声明重放 => 同一报告（200）；不同声明 => 409；完成后新块 => 409 =="
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE/uploads/$SID/complete" \
  -H 'Content-Type: application/json' \
  -d "{\"chunk_count\": 3, \"sha256\": \"$DIGEST\"}"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE/uploads/$SID/complete" \
  -H 'Content-Type: application/json' \
  -d '{"chunk_count": 3, "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}'
printf 'G1 X0\n' | curl -s -o /dev/null -w "HTTP %{http_code}\n" -X PUT "$BASE/uploads/$SID/chunks/3" --data-binary @-

echo "== 26) 缺块/摘要不符 => 409 且不留报告，会话保持 open 可继续 =="
SID2=$(curl -s -X POST "$BASE/uploads" \
  -H 'Content-Type: application/json' \
  -d '{"zones": [{"zone_no": 1, "version": 1}], "start": [-5, 50, 0],
       "tool_radius": 0.0}' | sed -n 's/.*"session_id":"\([0-9a-f]*\)".*/\1/p')
printf 'G1 X15 Y50 Z0\n' | curl -s -X PUT "$BASE/uploads/$SID2/chunks/0" --data-binary @- > /dev/null
curl -s -X POST "$BASE/uploads/$SID2/complete" \
  -H 'Content-Type: application/json' \
  -d '{"chunk_count": 2, "sha256": "'$(printf 'G1 X15 Y50 Z0\n' | sha256sum | cut -d' ' -f1)'"}'; echo

echo "== 27) 机床禁区基线：提交 MC-01 首版（版本 1），返回基线版本与固定禁区清单 =="
# 按机床编号固化一组互不重复的禁区编号+明确版本；组内编号重复 422、
# 禁区或版本不存在 404，且不写入基线
curl -s -X POST "$BASE/baselines" \
  -H 'Content-Type: application/json' \
  -d '{
        "machine_no": "MC-01",
        "zones": [{"zone_no": 1, "version": 1}],
        "description": "已核准的基座组合"
      }'; echo

echo "== 28) 用 机床编号+基线版本 代替 zones 提交审查（与直传 zones 同口径） =="
# 审查时解析为该基线版本固化的禁区版本快照；报告继续固化 used_zone_versions
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{
        "baseline": {"machine_no": "MC-01", "version": 1},
        "start": [-5, 5, 0],
        "tool_radius": 0.0,
        "gcode": "G21 G90 G17\nG1 X15 Y5 Z0\n"
      }'; echo

echo "== 29) 修订基线 => 递增不可变新版本（引用禁区 1 的 v2），旧版仍可查询 =="
curl -s -X POST "$BASE/baselines" \
  -H 'Content-Type: application/json' \
  -d '{
        "machine_no": "MC-01",
        "zones": [{"zone_no": 1, "version": 2}]
      }'; echo
curl -s "$BASE/baselines/MC-01"; echo

echo "== 30) 基线快照不可变：v1 仍按禁区 v1 判定（碰撞），v2 按 v2（无碰撞） =="
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{"baseline": {"machine_no": "MC-01", "version": 1}, "start": [-5, 5, 0],
       "tool_radius": 0.0, "gcode": "G1 X15 Y5 Z0\n"}'; echo
curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{"baseline": {"machine_no": "MC-01", "version": 2}, "start": [-5, 5, 0],
       "tool_radius": 0.0, "gcode": "G1 X15 Y5 Z0\n"}'; echo

echo "== 31) 批量任务与分块上传建会话同样可用 baseline；zones 与 baseline 同传 422 =="
curl -s -X POST "$BASE/reviews/batch" \
  -H 'Content-Type: application/json' \
  -d '{
        "batch_id": "BL-20261006-001",
        "items": [
          {"task_id": "via-baseline",
           "baseline": {"machine_no": "MC-01", "version": 1},
           "start": [-5, 5, 0], "tool_radius": 0.0,
           "gcode": "G1 X15 Y5 Z0\n"},
          {"task_id": "via-zones",
           "zones": [{"zone_no": 1, "version": 2}],
           "start": [-5, 5, 0], "tool_radius": 0.0,
           "gcode": "G1 X15 Y5 Z0\n"}
        ]
      }'; echo
SID3=$(curl -s -X POST "$BASE/uploads" \
  -H 'Content-Type: application/json' \
  -d '{"baseline": {"machine_no": "MC-01", "version": 1}, "start": [-5, 5, 0],
       "tool_radius": 0.0}' | sed -n 's/.*"session_id":"\([0-9a-f]*\)".*/\1/p')
printf 'G1 X15 Y5 Z0\n' | curl -s -X PUT "$BASE/uploads/$SID3/chunks/0" --data-binary @- > /dev/null
curl -s -X POST "$BASE/uploads/$SID3/complete" \
  -H 'Content-Type: application/json' \
  -d '{"chunk_count": 1, "sha256": "'$(printf 'G1 X15 Y5 Z0\n' | sha256sum | cut -d' ' -f1)'"}'; echo
curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{"zones": [{"zone_no": 1, "version": 1}],
       "baseline": {"machine_no": "MC-01", "version": 1},
       "start": [-5, 5, 0], "tool_radius": 0.0, "gcode": "G1 X1\n"}'

# ---- 工单刀路审查放行（v1.7）----
# 用专用机床 MC-REL 演示：先建当前基线 v1（引用禁区 1 的 v1），
# 再用该基线出具无碰撞报告并办理工单放行。
echo "== 32) 工单放行准备：建 MC-REL 基线 v1，并出具两份无碰撞报告 =="
curl -s -X POST "$BASE/baselines" \
  -H 'Content-Type: application/json' \
  -d '{"machine_no": "MC-REL",
       "zones": [{"zone_no": 1, "version": 1}],
       "description": "工单放行演示机床"}' > /dev/null
REL_R1=$(curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{"baseline": {"machine_no": "MC-REL", "version": 1},
       "start": [-5, 50, 0], "tool_radius": 0.0,
       "gcode": "G1 X15 Y50 Z0\n"}')
REL_R2=$(curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{"baseline": {"machine_no": "MC-REL", "version": 1},
       "start": [20, 20, 0], "tool_radius": 0.0,
       "gcode": "G1 X25 Y25 Z0\n"}')
REL_ID1=$(printf '%s' "$REL_R1" | sed -n 's/.*"report_id":\([0-9]*\).*/\1/p')
REL_ID2=$(printf '%s' "$REL_R2" | sed -n 's/.*"report_id":\([0-9]*\).*/\1/p')
echo "clear reports: $REL_ID1 $REL_ID2"

echo "== 33) 工单刀路审查放行：工单号 + 机床 + 预期基线版本 + 有序报告编号（201） =="
curl -s -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-20261007-001\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [$REL_ID2, $REL_ID1]
      }"; echo

echo "== 34) 同工单同内容重试 => 200，返回首次固化快照（不随后续修订改变） =="
curl -s -o /dev/null -w "replay HTTP %{http_code}\n" -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-20261007-001\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [$REL_ID2, $REL_ID1]
      }"

echo "== 35) 按工单查询固化快照 / 列全部放行概览 =="
curl -s "$BASE/releases/WO-20261007-001"; echo
curl -s "$BASE/releases" | python3 -c 'import sys,json; print([r["work_order_no"] for r in json.load(sys.stdin)])'

echo "== 36) 放行拒绝场景：异内容 409；碰撞报告 422；编号重复/数量越界 422 =="
# 同工单异内容（报告集合不同）=> release_conflict
curl -s -o /dev/null -w "different content HTTP %{http_code}\n" \
  -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-20261007-001\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [$REL_ID1]
      }"
# 碰撞报告（横穿禁区 1 v1）=> release_report_has_collision
HIT=$(curl -s -X POST "$BASE/reviews" \
  -H 'Content-Type: application/json' \
  -d '{"baseline": {"machine_no": "MC-REL", "version": 1},
       "start": [-5, 5, 0], "tool_radius": 0.0,
       "gcode": "G1 X15 Y5 Z0\n"}' | sed -n 's/.*"report_id":\([0-9]*\).*/\1/p')
curl -s -w "collision report HTTP %{http_code}\n" -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-BAD-001\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [$HIT]
      }"
# 报告编号重复 => 请求级 422
curl -s -o /dev/null -w "duplicate ids HTTP %{http_code}\n" -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-BAD-002\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [$REL_ID1, $REL_ID1]
      }"
# 不存在的报告编号 => 404，不留记录
curl -s -o /dev/null -w "missing report HTTP %{http_code}\n" -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-BAD-003\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [99999999]
      }"

echo "== 37) 修订基线后：旧工单同内容重试仍返回首次结果；新工单按旧版本 => 409 过期 =="
curl -s -X POST "$BASE/baselines" \
  -H 'Content-Type: application/json' \
  -d '{"machine_no": "MC-REL",
       "zones": [{"zone_no": 1, "version": 2}]}' > /dev/null
curl -s -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-20261007-001\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [$REL_ID2, $REL_ID1]
      }" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("replay frozen:", d["baseline_version"], d["machine_current_version"], d["report_ids"])'
curl -s -w "stale new work order HTTP %{http_code}\n" -o /dev/null \
  -X POST "$BASE/releases" \
  -H 'Content-Type: application/json' \
  -d "{
        \"work_order_no\": \"WO-STALE-001\",
        \"machine_no\": \"MC-REL\",
        \"expected_version\": 1,
        \"report_ids\": [$REL_ID1]
      }"
echo "failed work orders leave no records:"
curl -s "$BASE/releases" | python3 -c 'import sys,json; print([r["work_order_no"] for r in json.load(sys.stdin) if r["work_order_no"].startswith("WO-BAD") or r["work_order_no"]=="WO-STALE-001"])'
