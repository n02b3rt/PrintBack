"""Centralized dark theme constants."""

BG = "#14141c"
PANEL = "#1e1e2a"
PANEL_HOVER = "#262635"
FG = "#ddd"
MUTED = "#888"
ACCENT = (120, 200, 255, 200)  # rgba for pyqtgraph
ACCENT_HEX = "#78c8ff"
OK = "#7ee787"
WARN = "#ffcc66"
BAD = "#ff8080"

# whitelist source colors
WL_DEVICE = "#5b8def"   # captured via button
WL_MANUAL = "#888"       # manually labeled
WL_AUTO = "#ffcc66"      # heuristic

QSS = f"""
QMainWindow, QWidget {{ background: {BG}; color: {FG}; }}
QLabel {{ color: {FG}; }}
QTabWidget::pane {{ border: 0; background: {BG}; }}
QTabBar::tab {{
    background: {BG}; color: {MUTED};
    padding: 8px 18px; border: 0;
    border-bottom: 2px solid transparent;
}}
QTabBar::tab:selected {{
    color: {FG}; border-bottom: 2px solid {ACCENT_HEX};
}}
QTableWidget {{
    background: {PANEL}; color: {FG};
    gridline-color: #2a2a3a; border: 0;
    selection-background-color: {PANEL_HOVER};
    selection-color: {FG};
}}
QHeaderView::section {{
    background: {BG}; color: {MUTED};
    border: 0; padding: 6px; font-weight: bold;
}}
QStatusBar {{ background: {BG}; color: {MUTED}; }}
QSplitter::handle {{ background: {BG}; }}
QPlainTextEdit {{
    background: {PANEL}; color: {FG};
    border: 0; font-family: Consolas, monospace; font-size: 10px;
}}
QMenu {{ background: {PANEL}; color: {FG}; border: 1px solid #333; }}
QMenu::item:selected {{ background: {PANEL_HOVER}; }}
"""
