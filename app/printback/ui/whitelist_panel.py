from __future__ import annotations

import time
from typing import Callable

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QAction, QBrush, QColor
from PySide6.QtWidgets import (
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMenu,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from ..store import Store
from . import theme


def _format_age(ts: float) -> str:
    age = max(0, time.time() - ts)
    if age < 60:
        return f"{int(age)}s"
    if age < 3600:
        return f"{int(age // 60)}m"
    if age < 86400:
        return f"{int(age // 3600)}h"
    return f"{int(age // 86400)}d"


_SOURCE_COLOR = {
    "device": theme.WL_DEVICE,
    "manual": theme.WL_MANUAL,
    "auto": theme.WL_AUTO,
}


class WhitelistPanel(QWidget):
    changed = Signal()

    def __init__(self, store: Store, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.store = store
        self._suppress_change = False
        self._build_ui()

    def _build_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(6)

        header_row = QHBoxLayout()
        header = QLabel("whitelist")
        header.setStyleSheet(f"color: {theme.FG}; font-weight: bold; padding: 2px;")
        header_row.addWidget(header)
        header_row.addStretch()
        self.count_label = QLabel("0")
        self.count_label.setStyleSheet(f"color: {theme.MUTED};")
        header_row.addWidget(self.count_label)
        layout.addLayout(header_row)

        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["fingerprint", "label", "src", "age"])
        h = self.table.horizontalHeader()
        h.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        h.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        h.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        h.setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        self.table.verticalHeader().setVisible(False)
        self.table.itemChanged.connect(self._on_item_changed)
        self.table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.table.customContextMenuRequested.connect(self._on_context_menu)
        layout.addWidget(self.table)

    def refresh(self) -> None:
        rows = self.store.whitelist_rows()
        self._suppress_change = True
        try:
            self.table.setRowCount(len(rows))
            for i, (fp, label, added_at, source, reason) in enumerate(rows):
                short = fp[:12] + "…" if len(fp) > 12 else fp
                fp_item = QTableWidgetItem(short)
                fp_item.setFlags(fp_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                fp_item.setData(Qt.ItemDataRole.UserRole, fp)
                tooltip = f"{fp}\nadded: {time.ctime(added_at)}"
                if reason:
                    tooltip += f"\nreason: {reason}"
                fp_item.setToolTip(tooltip)

                label_item = QTableWidgetItem(label or "")
                label_item.setData(Qt.ItemDataRole.UserRole, fp)

                src_item = QTableWidgetItem(source or "")
                src_item.setFlags(src_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                color = _SOURCE_COLOR.get(source, theme.MUTED)
                src_item.setForeground(QBrush(QColor(color)))
                src_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)

                age_item = QTableWidgetItem(_format_age(added_at))
                age_item.setFlags(age_item.flags() & ~Qt.ItemFlag.ItemIsEditable)
                age_item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)

                self.table.setItem(i, 0, fp_item)
                self.table.setItem(i, 1, label_item)
                self.table.setItem(i, 2, src_item)
                self.table.setItem(i, 3, age_item)

            self.count_label.setText(str(len(rows)))
        finally:
            self._suppress_change = False

    def _on_item_changed(self, item: QTableWidgetItem) -> None:
        if self._suppress_change or item.column() != 1:
            return
        fp = item.data(Qt.ItemDataRole.UserRole)
        if not fp:
            return
        self.store.set_label(fp, item.text().strip() or None)

    def _on_context_menu(self, pos) -> None:
        row = self.table.rowAt(pos.y())
        if row < 0:
            return
        fp_item = self.table.item(row, 0)
        if fp_item is None:
            return
        fp = fp_item.data(Qt.ItemDataRole.UserRole)
        src_item = self.table.item(row, 2)
        source = src_item.text() if src_item else ""

        menu = QMenu(self)
        remove_act = QAction("usuń z whitelisty", self)
        remove_act.triggered.connect(lambda: self._remove(fp))
        menu.addAction(remove_act)

        if source == "auto":
            fp_act = QAction("oznacz jako false-positive (nie auto-WL ponownie)", self)
            fp_act.triggered.connect(lambda: self._false_positive(fp))
            menu.addAction(fp_act)

        menu.exec(self.table.viewport().mapToGlobal(pos))

    def _remove(self, fp: str) -> None:
        self.store.remove_whitelist(fp)
        self.refresh()
        self.changed.emit()

    def _false_positive(self, fp: str) -> None:
        self.store.mark_false_positive(fp, note="user override")
        self.refresh()
        self.changed.emit()

    def add_manual(self, fp: str, label: str | None = None) -> None:
        if self.store.remember_whitelisted(fp, source="manual"):
            if label:
                self.store.set_label(fp, label)
        self.refresh()
        self.changed.emit()
