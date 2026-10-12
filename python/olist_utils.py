"""
olist_utils.py
项目通用工具：连接数据库、执行查询、统一图表风格

用法（在笔记本第一个单元格中；需先在项目根目录建立 .env 文件，见下方说明）：
    from olist_utils import run_query, set_style, COLORS
    set_style()
    df = run_query("SELECT ...")

作者：LeeMichael-L    日期：2026-10-12
"""

from getpass import getpass
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
from sqlalchemy import URL, create_engine, text

# ---------------------------------------------------------------------
# 1. 数据库连接
#    密码不写在代码里，而是放在项目根目录的 .env 文件中：
#        MYSQL_PASSWORD=你的密码
#    .env 已写入 .gitignore，不会被提交到 GitHub。
#    如果找不到 .env，才退回到弹出输入框询问密码。
# ---------------------------------------------------------------------
_engine = None
ENV_FILE = Path(__file__).resolve().parent.parent / ".env"   # 项目根目录下的 .env


def _read_password() -> str:
    """优先从 .env 读取密码；读不到再弹框询问。"""
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("MYSQL_PASSWORD="):
                return line.split("=", 1)[1].strip()
    return getpass("MySQL root 密码：")


def get_engine():
    """返回数据库连接；第一次调用时读取密码，同一会话内只读一次。"""
    global _engine
    if _engine is None:
        password = _read_password()
        url = URL.create(
            drivername="mysql+pymysql",
            username="root",
            password=password,      # URL.create 会自动处理密码中的特殊字符
            host="localhost",
            port=3306,
            database="olist",
            query={"charset": "utf8mb4"},
        )
        _engine = create_engine(url)
    return _engine


def run_query(sql: str) -> pd.DataFrame:
    """执行一条 SQL，把结果作为 pandas 表格返回。"""
    with get_engine().connect() as conn:
        return pd.read_sql(text(sql), conn)


# ---------------------------------------------------------------------
# 2. 图表风格
#    颜色：系列按固定顺序取色；文字用中性的深色/灰色，不用系列颜色
# ---------------------------------------------------------------------
COLORS = {
    "blue": "#2a78d6",     # 默认系列色（第1个系列）
    "orange": "#eb6834",   # 第2个系列
    "aqua": "#1baf7a",     # 第3个系列
    "gray": "#b8b7b1",     # 背景、对照数据（强调图里"其余"部分）
    "text": "#0b0b0b",     # 主要文字
    "text_secondary": "#52514e",  # 次要文字：坐标轴、注释
    "grid": "#e6e5e0",     # 网格线
    "surface": "#fcfcfb",  # 图表背景
}


def set_style():
    """统一所有图表的基础风格。每个笔记本开头调用一次。"""
    plt.rcParams.update({
        # 中文字体：Windows 用微软雅黑；其余为备选
        "font.sans-serif": ["Microsoft YaHei", "SimHei", "Noto Sans CJK SC",
                            "PingFang SC", "DejaVu Sans"],
        "axes.unicode_minus": False,        # 负号正常显示
        "figure.figsize": (10, 4.5),
        "figure.dpi": 110,
        "figure.facecolor": COLORS["surface"],
        "axes.facecolor": COLORS["surface"],
        # 坐标轴和网格：弱化，让数据成为主角
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.edgecolor": COLORS["grid"],
        "axes.grid": True,
        "axes.grid.axis": "y",
        "grid.color": COLORS["grid"],
        "grid.linewidth": 0.8,
        "axes.axisbelow": True,
        # 文字
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.titlelocation": "left",
        "axes.titlecolor": COLORS["text"],
        "axes.labelcolor": COLORS["text_secondary"],
        "xtick.color": COLORS["text_secondary"],
        "ytick.color": COLORS["text_secondary"],
        "xtick.major.size": 0,
        "ytick.major.size": 0,
        # 线条
        "lines.linewidth": 2,
    })