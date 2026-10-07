"""ORM 模型。

- zones：禁区逻辑实体（编号唯一）；
- zone_versions：禁区的不可变版本，每次修改产生新版本，旧版本保留；
- zone_baselines：机床禁区基线（机床编号 + 递增版本），固化一组互不重复的
  禁区编号与明确版本；每次修订产生递增且不可变的新版本，旧版本保留；
- reports：审查报告，创建后不可变，不随后续禁区版本变化；
- batches：批量审查批次（batch_id 幂等键 + 内容哈希 + 逐项结果快照）；
- upload_sessions / upload_chunks：长 G-code 可恢复分块上传会话及其文本块，
  全部状态落库，跨服务重启保留；
- machine_locks：按机床编号的串行锁，基线修订与工单放行取同一把锁，
  保证放行判定与放行记录对应同一基线版本状态；
- work_order_releases：工单刀路审查放行（工单号幂等键 + 内容哈希 +
  机床/基线版本/有序报告编号 + 完整结果快照），放行后不可变。
"""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import (JSON, CheckConstraint, Column, DateTime, Float,
                        ForeignKey, Index, Integer, String, Text, Boolean)
from sqlalchemy.orm import relationship

from .database import Base


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Zone(Base):
    __tablename__ = "zones"

    id = Column(Integer, primary_key=True)
    zone_no = Column(Integer, nullable=False, unique=True)
    description = Column(String(500), nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)

    versions = relationship("ZoneVersion", back_populates="zone",
                            order_by="ZoneVersion.version")


class ZoneVersion(Base):
    __tablename__ = "zone_versions"
    __table_args__ = (
        CheckConstraint("version >= 1", name="ck_version_positive"),
        Index("ix_zone_version", "zone_id", "version", unique=True),
    )

    id = Column(Integer, primary_key=True)
    zone_id = Column(Integer, ForeignKey("zones.id"), nullable=False)
    version = Column(Integer, nullable=False)
    # 毫米制二维多边形顶点 [[x, y], ...]
    polygon = Column(JSON, nullable=False)
    z_min = Column(Float, nullable=False)
    z_max = Column(Float, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)

    zone = relationship("Zone", back_populates="versions")


class ZoneBaseline(Base):
    """机床禁区基线（v1.6）：按机床编号固化一组互不重复的禁区编号+明确版本。

    首版为 1；同一机床编号再次提交（修订）产生递增且不可变的新版本，
    旧版本永久保留可查询。(machine_no, version) 唯一约束兜底并发修订：
    并发提交各自获得不同版本号，不丢失任何已成功提交的版本。
    单项审查、批量任务与分块上传建会话可用 机床编号+基线版本 代替
    zones，审查时解析为该基线版本固化的禁区版本快照。
    """

    __tablename__ = "zone_baselines"
    __table_args__ = (
        CheckConstraint("version >= 1", name="ck_baseline_version_positive"),
        Index("ix_zone_baseline_machine_version", "machine_no", "version",
              unique=True),
    )

    id = Column(Integer, primary_key=True)
    # 机床编号（字母数字开头，可含 _ . : -，最长 64）
    machine_no = Column(String(64), nullable=False)
    version = Column(Integer, nullable=False)
    # 固化的禁区清单 [{"zone_no": int, "version": int}, ...]，按编号升序
    zones = Column(JSON, nullable=False)
    description = Column(String(500), nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)


class Report(Base):
    """审查报告：保存即不可变。"""

    __tablename__ = "reports"

    id = Column(Integer, primary_key=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)

    # 审查所用禁区版本快照（zone_no -> version_id/version）
    zone_versions = Column(JSON, nullable=False)
    # 输入摘要
    input_summary = Column(JSON, nullable=False)

    has_collision = Column(Boolean, nullable=False)
    collision_line_no = Column(Integer, nullable=True)
    collision_zone_no = Column(Integer, nullable=True)
    conclusion = Column(Text, nullable=False)

    # 多刀模式/命中固化：首碰撞发生时生效刀号（初始刀位为空）与半径（mm）。
    # 旧请求/旧报告这两列为 NULL，读取保持兼容。
    collision_tool_no = Column(Integer, nullable=True)
    collision_tool_radius = Column(Float, nullable=True)

    # 可选的全程最小水平净间隙（仅 include_min_clearance=true 的报告固化）
    min_clearance_enabled = Column(Boolean, nullable=False, default=False,
                                   server_default="0")
    # {min_clearance_mm, line_no, point_mm, zone_no, progress,
    #  tool_no, tool_radius_mm} 或 None
    min_clearance = Column(JSON, nullable=True)

    # 多刀模式固化的执行事件轨迹（仅 tool_radii 启用的报告）：
    # [{seq, kind, line_no, tool_no, tool_radius_mm, start_mm, end_mm,
    #   hit_zone_no}, ...]；单刀请求与旧报告为 NULL
    execution_trace = Column(JSON, nullable=True)


class Batch(Base):
    """批量审查批次：与整批报告在同一事务提交。

    batch_id 为幂等键（唯一约束兜底并发）；content_hash 为批内容
    （逐项规范化请求）的 SHA-256，用于区分重放与冲突：
    相同 batch_id + 相同内容 => 重放首次逐项结果（results 快照原样返回）；
    相同 batch_id + 不同内容 => 由 API 层返回 409，不新增行、不生成报告。
    """

    __tablename__ = "batches"

    id = Column(Integer, primary_key=True)
    batch_id = Column(String(64), nullable=False, unique=True)
    # 批内容（逐项规范化请求）的 SHA-256
    content_hash = Column(String(64), nullable=False)
    item_count = Column(Integer, nullable=False)
    # 逐项结果快照 [{index, task_id, result: {report_id, ...}}]，按输入顺序
    results = Column(JSON, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)


class UploadSession(Base):
    """长 G-code 分块上传会话（v1.5）。

    创建时冻结审查参数（禁区编号 + 明确版本、初始刀尖坐标、刀半径、
    可选多刀映射 / 最小净间隙开关），返回对外会话标识 session_id。
    状态机：open -> completing（条件 UPDATE 抢占的事务内过渡态，
    提交前对外不可见，崩溃自动回滚为 open）-> completed。
    完成时冻结声明（块数 + 拼接文本 SHA-256）与响应快照：
    相同声明重放/并发返回同一报告，不同声明冲突，完成后拒绝新块。
    """

    __tablename__ = "upload_sessions"

    id = Column(Integer, primary_key=True)
    # 对外会话标识（uuid4 hex，32 位，URL 安全）
    session_id = Column(String(32), nullable=False, unique=True)
    status = Column(String(16), nullable=False, default="open")
    # 冻结的审查参数（与 ReviewRequest 同形，缺 gcode）
    params = Column(JSON, nullable=False)
    received_count = Column(Integer, nullable=False, default=0)
    total_bytes = Column(Integer, nullable=False, default=0)
    # 完成时声明的正整数块数与拼接文本 SHA-256（小写 hex）
    declared_chunk_count = Column(Integer, nullable=True)
    declared_sha256 = Column(String(64), nullable=True)
    # 完成生成的不可变报告与响应快照（ReviewResponse JSON，重放原样返回）
    report_id = Column(Integer, ForeignKey("reports.id"), nullable=True)
    result = Column(JSON, nullable=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)
    completed_at = Column(DateTime(timezone=True), nullable=True)

    chunks = relationship("UploadChunk", back_populates="session",
                          order_by="UploadChunk.seq")


class UploadChunk(Base):
    """上传会话中的单个 UTF-8 文本块（序号从 0 起，可乱序到达）。

    (upload_id, seq) 唯一约束兜底并发同号块：同号同内容重传幂等返回
    原回执，同号异内容冲突（不覆盖）。单块 <= 64 KiB，会话总量 <= 8 MiB。
    """

    __tablename__ = "upload_chunks"
    __table_args__ = (
        CheckConstraint("seq >= 0", name="ck_chunk_seq_nonneg"),
        Index("ix_upload_chunk_seq", "upload_id", "seq", unique=True),
    )

    id = Column(Integer, primary_key=True)
    upload_id = Column(Integer, ForeignKey("upload_sessions.id"),
                       nullable=False)
    seq = Column(Integer, nullable=False)
    byte_len = Column(Integer, nullable=False)
    # 块内容（原始字节）的 SHA-256，用于重传幂等判定
    sha256 = Column(String(64), nullable=False)
    data = Column(Text, nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)

    session = relationship("UploadSession", back_populates="chunks")


class MachineLock(Base):
    """按机床编号的串行锁表（v1.7）。

    每个机床编号一行；基线修订（POST /baselines）与工单放行
    （POST /releases）在读取/推进该机床基线当前版本前先取这把锁，
    使「基线修订」与「放行判定 + 放行记录」对同一机床严格串行：
    放行事务在锁内确认预期版本仍是当前版本并完成固化，期间基线无法
    修订插入新版本，判定与记录必然对应同一版本状态。
    """

    __tablename__ = "machine_locks"

    id = Column(Integer, primary_key=True)
    machine_no = Column(String(64), nullable=False, unique=True)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)


class WorkOrderRelease(Base):
    """工单刀路审查放行（v1.7）：车间按工单锁定一台机床的放行结果。

    work_order_no 为幂等键（唯一约束兜底并发）；content_hash 为放行内容
    （机床编号、预期基线版本、有序报告编号）规范化后的 SHA-256，
    用于区分重放与冲突：
    相同工单 + 相同内容 => 重放首次放行结果（result 快照原样返回），
    即使该机床基线后续已修订；相同工单 + 不同内容 => 409，不新增行。

    成功放行时固化工单号、机床编号、基线版本、按输入顺序的报告编号
    （report_ids）、放行时该机床当前版本（machine_current_version，应等于
    固化基线版本）与放行时间（released_at）；result 为完整响应快照，
    按工单查询永远返回该快照，不随后续基线/禁区修订改变。
    """

    __tablename__ = "work_order_releases"

    id = Column(Integer, primary_key=True)
    work_order_no = Column(String(64), nullable=False, unique=True)
    # 放行内容（机床编号 + 预期基线版本 + 有序报告编号）的 SHA-256
    content_hash = Column(String(64), nullable=False)
    machine_no = Column(String(64), nullable=False)
    # 放行时固化的机床基线版本（= 请求的预期版本）
    baseline_version = Column(Integer, nullable=False)
    # 放行时刻该机床当前（最大）基线版本；首次放行时与 baseline_version 相同
    machine_current_version = Column(Integer, nullable=False)
    # 按输入顺序固化的报告编号（1～50 个，互不重复）
    report_ids = Column(JSON, nullable=False)
    report_count = Column(Integer, nullable=False)
    # 首次放行完整响应快照（ReleaseResponse JSON，重放原样返回）
    result = Column(JSON, nullable=False)
    released_at = Column(DateTime(timezone=True), nullable=False,
                         default=_utcnow)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)
