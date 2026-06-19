#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "AppStoreAssets" / "2026-06-17"
ICON_PATH = ROOT / "XConnectFTP" / "Assets.xcassets" / "AppIcon.appiconset" / "icon_512x512@2x.png"

SCREENSHOT_SIZE = (2880, 1800)
PREVIEW_SIZE = (1920, 1080)
FPS = 30
SEGMENT_SECONDS = 3.0

FONT_REGULAR = "/System/Library/Fonts/SFNS.ttf"
FONT_ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

COLORS = {
    "ink": "#0C1222",
    "muted": "#526071",
    "line": "#D6DEE8",
    "panel": "#FFFFFF",
    "panel_alt": "#F7FAFC",
    "teal": "#0F766E",
    "teal_soft": "#DDF7F2",
    "blue": "#2563EB",
    "blue_soft": "#E8F0FF",
    "amber": "#F59E0B",
    "amber_soft": "#FFF3D7",
    "red": "#E04F43",
    "green": "#16A34A",
    "shadow": "#163046",
}


LANG = {
    "en": {
        "brand": "XConnectFTP",
        "kicker": "Mac FTP/FTPS client",
        "screens": [
            {
                "slug": "01-dual-pane-workspace",
                "title": "Dual-pane FTP/FTPS workspace",
                "subtitle": "Browse local and remote folders side by side with native macOS tables.",
                "mode": "browser",
            },
            {
                "slug": "02-saved-sites",
                "title": "Saved sites, fast switching",
                "subtitle": "Keep connection metadata, local roots and remote paths ready for repeat work.",
                "mode": "connecting",
            },
            {
                "slug": "03-search-sort",
                "title": "Search and sort without losing flow",
                "subtitle": "Pane-specific search and sortable Name, Size and Modified columns keep large folders readable.",
                "mode": "search",
            },
            {
                "slug": "04-drag-copy-paste",
                "title": "Drag, drop, copy and paste",
                "subtitle": "Move files between Finder-like panes with selection, context menus and keyboard shortcuts.",
                "mode": "drag",
            },
            {
                "slug": "05-ftps-security",
                "title": "Explicit FTPS with clear safety signals",
                "subtitle": "Use encrypted FTP when available and keep insecure FTP warnings visible.",
                "mode": "security",
            },
            {
                "slug": "06-transfer-progress",
                "title": "Progress that stays visible",
                "subtitle": "Track folder downloads, per-file progress and cancellation from the footer.",
                "mode": "transfer",
            },
            {
                "slug": "07-settings-localization",
                "title": "Localized settings and iCloud metadata sync",
                "subtitle": "Switch language and appearance, then sync saved-site metadata without syncing passwords.",
                "mode": "settings",
            },
        ],
        "ui": {
            "saved_sites": "Saved Sites",
            "new_site": "New Site",
            "connected": "Connected to files.example.com via FTPS.",
            "local": "Local",
            "remote": "Remote",
            "search": "Search",
            "upload": "Upload",
            "download": "Download",
            "new_folder": "New Folder",
            "rename": "Rename",
            "delete": "Delete",
            "choose_root": "Choose Local Root",
            "settings": "Settings",
            "sync": "Sync saved sites with iCloud",
            "language": "Language",
            "appearance": "Interface",
            "metadata": "Passwords remain in the local Keychain on this Mac.",
            "progress": "Downloading uploads/client-photos.zip",
            "cancel": "Cancel Transfer",
            "warning": "Current connection uses encrypted explicit FTPS.",
            "context": ["Open", "Download", "Copy", "Rename", "Delete"],
            "shortcuts": "Cmd+C / Cmd+V",
        },
    },
    "vi": {
        "brand": "XConnectFTP",
        "kicker": "FTP/FTPS client cho macOS",
        "screens": [
            {
                "slug": "01-khong-gian-hai-khung",
                "title": "Không gian FTP/FTPS hai khung",
                "subtitle": "Duyệt thư mục local và remote cạnh nhau bằng bảng macOS quen thuộc.",
                "mode": "browser",
            },
            {
                "slug": "02-site-da-luu",
                "title": "Site đã lưu, chuyển kết nối nhanh",
                "subtitle": "Giữ metadata kết nối, thư mục local và remote path sẵn sàng cho công việc lặp lại.",
                "mode": "connecting",
            },
            {
                "slug": "03-tim-kiem-sap-xep",
                "title": "Tìm kiếm và sắp xếp mạch lạc",
                "subtitle": "Tìm kiếm riêng từng khung, sắp xếp theo Name, Size và Modified khi thư mục lớn.",
                "mode": "search",
            },
            {
                "slug": "04-keo-tha-copy-paste",
                "title": "Kéo thả, sao chép và dán",
                "subtitle": "Di chuyển file giữa hai khung bằng selection, menu ngữ cảnh và phím tắt.",
                "mode": "drag",
            },
            {
                "slug": "05-bao-mat-ftps",
                "title": "FTPS rõ ràng, cảnh báo dễ hiểu",
                "subtitle": "Dùng FTP mã hóa khi server hỗ trợ và luôn hiển thị cảnh báo nếu dùng FTP thường.",
                "mode": "security",
            },
            {
                "slug": "06-tien-trinh-truyen-tai",
                "title": "Tiến trình truyền tải luôn nhìn thấy",
                "subtitle": "Theo dõi download thư mục, tiến trình từng file và hủy tác vụ ngay ở footer.",
                "mode": "transfer",
            },
            {
                "slug": "07-cai-dat-dong-bo",
                "title": "Cài đặt đa ngôn ngữ và đồng bộ iCloud",
                "subtitle": "Đổi ngôn ngữ, giao diện và đồng bộ metadata site mà không đồng bộ password.",
                "mode": "settings",
            },
        ],
        "ui": {
            "saved_sites": "Site đã lưu",
            "new_site": "Tạo site",
            "connected": "Đã kết nối tới files.example.com qua FTPS.",
            "local": "Local",
            "remote": "Remote",
            "search": "Tìm kiếm",
            "upload": "Upload",
            "download": "Download",
            "new_folder": "Thư mục mới",
            "rename": "Đổi tên",
            "delete": "Xóa",
            "choose_root": "Chọn thư mục gốc",
            "settings": "Cài đặt",
            "sync": "Đồng bộ site đã lưu với iCloud",
            "language": "Ngôn ngữ",
            "appearance": "Giao diện",
            "metadata": "Password vẫn chỉ nằm trong Keychain local trên máy Mac này.",
            "progress": "Đang download uploads/client-photos.zip",
            "cancel": "Hủy truyền tải",
            "warning": "Kết nối hiện tại dùng explicit FTPS đã mã hóa.",
            "context": ["Mở", "Download", "Sao chép", "Đổi tên", "Xóa"],
            "shortcuts": "Cmd+C / Cmd+V",
        },
    },
}


LOCAL_ROWS = [
    ("folder", "public_html", "--", "Today, 09:41"),
    ("folder", "assets", "--", "Today, 09:38"),
    ("folder", "release", "--", "Yesterday, 18:12"),
    ("file", "index.html", "38 KB", "Today, 09:35"),
    ("file", ".htaccess", "2 KB", "Today, 09:33"),
    ("file", "style.css", "74 KB", "Yesterday, 17:44"),
    ("file", "backup-2026-06.zip", "148 MB", "Mon, 22:10"),
]

REMOTE_ROWS = [
    ("folder", "www", "--", "Today, 10:02"),
    ("folder", "uploads", "--", "Today, 09:59"),
    ("folder", "logs", "--", "Yesterday, 23:51"),
    ("file", "app-release.zip", "96 MB", "Today, 09:57"),
    ("file", "sitemap.xml", "11 KB", "Today, 09:45"),
    ("file", "logo.png", "420 KB", "Yesterday, 16:20"),
    ("file", "error.log", "1.2 MB", "Yesterday, 14:03"),
]

SAVED_SITES = [
    ("Production FTPS", "files.example.com", True),
    ("Staging", "staging.example.com", False),
    ("Client CDN", "cdn.example.net", False),
    ("Legacy FTP", "ftp.legacy.local", False),
]


def color(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def with_alpha(rgb: str | tuple[int, int, int], alpha: int) -> tuple[int, int, int, int]:
    base = color(rgb) if isinstance(rgb, str) else rgb
    return (*base, alpha)


def font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    path = {
        "regular": FONT_REGULAR,
        "rounded": FONT_ROUNDED,
        "mono": FONT_MONO,
        "bold": FONT_BOLD,
    }.get(weight, FONT_REGULAR)
    return ImageFont.truetype(path, size)


def text_size(draw: ImageDraw.ImageDraw, text: str, fnt: ImageFont.FreeTypeFont) -> tuple[int, int]:
    bbox = draw.textbbox((0, 0), text, font=fnt)
    return bbox[2] - bbox[0], bbox[3] - bbox[1]


def wrap_text(draw: ImageDraw.ImageDraw, text: str, fnt: ImageFont.FreeTypeFont, max_width: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = word if not current else f"{current} {word}"
        if draw.textlength(candidate, font=fnt) <= max_width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def draw_wrapped(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    text: str,
    fnt: ImageFont.FreeTypeFont,
    fill: str | tuple[int, int, int],
    max_width: int,
    line_gap: int,
) -> int:
    x, y = xy
    for line in wrap_text(draw, text, fnt, max_width):
        draw.text((x, y), line, font=fnt, fill=fill)
        _, h = text_size(draw, line, fnt)
        y += h + line_gap
    return y


def gradient_background(size: tuple[int, int]) -> Image.Image:
    w, h = size
    x = np.linspace(0, 1, w, dtype=np.float32)
    y = np.linspace(0, 1, h, dtype=np.float32)
    xv, yv = np.meshgrid(x, y)
    t = (xv * 0.35 + yv * 0.65)

    a = np.array(color("#F7FAFC"), dtype=np.float32)
    b = np.array(color("#EAF7F3"), dtype=np.float32)
    c = np.array(color("#EDF3FF"), dtype=np.float32)
    img = ((1 - t[..., None]) * a + t[..., None] * b).astype(np.float32)
    diagonal = np.clip((xv - yv + 0.45) * 1.2, 0, 1)
    img = img * (1 - 0.35 * diagonal[..., None]) + c * (0.35 * diagonal[..., None])
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def rounded_layer(size: tuple[int, int], radius: int, fill: str | tuple[int, int, int, int]) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=fill)
    return layer


def shadowed_rect(
    img: Image.Image,
    box: tuple[int, int, int, int],
    radius: int,
    fill: str,
    shadow_alpha: int = 45,
    shadow_radius: int = 36,
    offset: tuple[int, int] = (0, 18),
) -> None:
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(shadow)
    ox, oy = offset
    d.rounded_rectangle(
        (x0 + ox, y0 + oy, x1 + ox, y1 + oy),
        radius=radius,
        fill=with_alpha(COLORS["shadow"], shadow_alpha),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(shadow_radius))
    img.alpha_composite(shadow)
    img.alpha_composite(rounded_layer((w, h), radius, color(fill) + (255,)), (x0, y0))


def load_icon(size: int) -> Image.Image:
    icon = Image.open(ICON_PATH).convert("RGBA")
    icon.thumbnail((size, size), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(icon, ((size - icon.width) // 2, (size - icon.height) // 2))
    return canvas


def draw_pill(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], text: str, fill: str, fg: str, size: int) -> None:
    draw.rounded_rectangle(box, radius=(box[3] - box[1]) // 2, fill=fill)
    fnt = font(size, "bold")
    tw, th = text_size(draw, text, fnt)
    draw.text(
        ((box[0] + box[2] - tw) // 2, (box[1] + box[3] - th) // 2 - 2),
        text,
        font=fnt,
        fill=fg,
    )


def draw_folder(draw: ImageDraw.ImageDraw, x: int, y: int, s: int, fill: str) -> None:
    draw.rounded_rectangle((x, y + s * 0.25, x + s, y + s * 0.82), radius=max(4, s // 8), fill=fill)
    draw.rounded_rectangle((x + s * 0.08, y + s * 0.12, x + s * 0.5, y + s * 0.38), radius=max(3, s // 10), fill=fill)


def draw_file(draw: ImageDraw.ImageDraw, x: int, y: int, s: int, fill: str, line: str) -> None:
    draw.rounded_rectangle((x, y, x + s * 0.76, y + s), radius=max(3, s // 12), fill=fill)
    draw.polygon([(x + s * 0.52, y), (x + s * 0.76, y), (x + s * 0.76, y + s * 0.24)], fill="#C8D2E0")
    draw.rounded_rectangle((x + s * 0.16, y + s * 0.42, x + s * 0.6, y + s * 0.52), radius=2, fill=line)
    draw.rounded_rectangle((x + s * 0.16, y + s * 0.62, x + s * 0.52, y + s * 0.72), radius=2, fill=line)


def draw_search(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], placeholder: str, value: str = "") -> None:
    draw.rounded_rectangle(box, radius=(box[3] - box[1]) // 2, fill="#F3F6FA", outline="#D7E0EA", width=2)
    cx, cy = box[0] + 24, (box[1] + box[3]) // 2
    draw.ellipse((cx - 7, cy - 7, cx + 7, cy + 7), outline="#8592A4", width=3)
    draw.line((cx + 9, cy + 9, cx + 18, cy + 18), fill="#8592A4", width=3)
    text = value or placeholder
    fill = COLORS["ink"] if value else "#8B97A7"
    draw.text((box[0] + 54, box[1] + 12), text, font=font(26), fill=fill)


def draw_table(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    title: str,
    rows: list[tuple[str, str, str, str]],
    search_label: str,
    search_value: str = "",
    selected: set[int] | None = None,
    highlight_sort: bool = False,
) -> None:
    selected = selected or set()
    x0, y0, x1, y1 = box
    draw.rounded_rectangle(box, radius=22, fill=COLORS["panel"], outline="#DCE5EE", width=2)
    draw.text((x0 + 34, y0 + 30), title, font=font(34, "bold"), fill=COLORS["ink"])
    draw_search(draw, (x1 - 420, y0 + 22, x1 - 32, y0 + 72), search_label, search_value)

    header_y = y0 + 102
    draw.line((x0, header_y, x1, header_y), fill="#DFE7EF", width=2)
    columns = [(x0 + 78, "Name", 0.0), (x1 - 420, "Size", 0.0), (x1 - 230, "Modified", 0.0)]
    for cx, label, _ in columns:
        draw.text((cx, header_y + 22), label, font=font(23, "bold"), fill="#607085")
    if highlight_sort:
        draw.text((x0 + 154, header_y + 19), "↓", font=font(26, "bold"), fill=COLORS["blue"])

    row_h = 72
    first_y = header_y + 66
    for i, row in enumerate(rows[:7]):
        kind, name, size, modified = row
        y = first_y + i * row_h
        if i in selected:
            draw.rounded_rectangle((x0 + 18, y + 6, x1 - 18, y + row_h - 6), radius=12, fill="#E8F0FF")
        elif i % 2 == 1:
            draw.rectangle((x0 + 18, y + 4, x1 - 18, y + row_h - 4), fill="#FBFCFE")
        if kind == "folder":
            draw_folder(draw, x0 + 34, y + 16, 36, "#64B5F6")
        else:
            draw_file(draw, x0 + 38, y + 12, 40, "#ECF2FA", "#99A8BA")
        draw.text((x0 + 86, y + 19), name, font=font(26), fill=COLORS["ink"])
        draw.text((x1 - 420, y + 19), size, font=font(24), fill="#607085")
        draw.text((x1 - 230, y + 19), modified, font=font(24), fill="#607085")


def draw_sidebar(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], ui: dict[str, str], mode: str) -> None:
    x0, y0, x1, y1 = box
    draw.rectangle(box, fill="#F7FAFC")
    draw.text((x0 + 30, y0 + 32), ui["saved_sites"], font=font(31, "bold"), fill=COLORS["ink"])
    draw.rounded_rectangle((x0 + 30, y0 + 90, x1 - 30, y0 + 144), radius=14, fill=COLORS["blue"])
    draw.text((x0 + 74, y0 + 104), ui["new_site"], font=font(24, "bold"), fill="white")
    draw.text((x0 + 48, y0 + 103), "+", font=font(28, "bold"), fill="white")

    y = y0 + 176
    for idx, (name, host, active) in enumerate(SAVED_SITES):
        selected = active or (mode == "connecting" and idx == 1)
        if selected:
            draw.rounded_rectangle((x0 + 20, y, x1 - 18, y + 86), radius=18, fill="#E8F0FF")
        draw.text((x0 + 48, y + 16), name, font=font(25, "bold"), fill=COLORS["ink"])
        draw.text((x0 + 48, y + 49), host, font=font(21), fill="#677589")
        if active:
            draw.ellipse((x1 - 58, y + 31, x1 - 38, y + 51), fill=COLORS["green"])
        y += 96


def draw_toolbar(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], ui: dict[str, str], mode: str) -> None:
    x0, y0, x1, y1 = box
    draw.rectangle(box, fill="#FFFFFF")
    if mode == "connecting":
        status = "Connecting to staging.example.com..."
    else:
        status = ui["connected"]
    draw.text((x0 + 32, y0 + 24), status, font=font(27, "bold"), fill=COLORS["ink"])
    draw.text((x0 + 32, y0 + 59), "/var/www/current", font=font(22), fill="#68778B")

    buttons = [
        (ui["choose_root"], COLORS["teal_soft"], COLORS["teal"]),
        (ui["upload"], COLORS["blue_soft"], COLORS["blue"]),
        (ui["download"], COLORS["blue_soft"], COLORS["blue"]),
    ]
    bx = x1 - 760
    for label, fill, fg in buttons:
        width = 210 if len(label) < 12 else 270
        draw_pill(draw, (bx, y0 + 28, bx + width, y0 + 74), label, fill, fg, 21)
        bx += width + 18


def draw_transfer_footer(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], ui: dict[str, str], active: bool) -> None:
    x0, y0, x1, y1 = box
    draw.rectangle(box, fill="#F9FBFD")
    draw.line((x0, y0, x1, y0), fill="#DCE5EE", width=2)
    msg = ui["progress"] if active else ui["connected"]
    draw.text((x0 + 32, y0 + 26), msg, font=font(24, "bold"), fill=COLORS["ink"])
    if active:
        draw.rounded_rectangle((x0 + 32, y0 + 66, x0 + 720, y0 + 86), radius=10, fill="#E2E8F0")
        draw.rounded_rectangle((x0 + 32, y0 + 66, x0 + 480, y0 + 86), radius=10, fill=COLORS["blue"])
        draw.text((x0 + 744, y0 + 58), "64%", font=font(23, "bold"), fill=COLORS["blue"])
        draw_pill(draw, (x1 - 210, y0 + 34, x1 - 42, y0 + 84), ui["cancel"], "#FEE2E2", COLORS["red"], 20)


def draw_context_menu(draw: ImageDraw.ImageDraw, x: int, y: int, ui: dict[str, str]) -> None:
    w, row = 270, 46
    h = row * len(ui["context"]) + 22
    draw.rounded_rectangle((x, y, x + w, y + h), radius=18, fill="white", outline="#D7E0EA", width=2)
    for i, label in enumerate(ui["context"]):
        yy = y + 12 + i * row
        if i == 1:
            draw.rounded_rectangle((x + 10, yy - 4, x + w - 10, yy + row - 6), radius=10, fill="#E8F0FF")
        draw.text((x + 28, yy + 6), label, font=font(23), fill=COLORS["ink"] if i != 4 else COLORS["red"])


def draw_security_banner(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], ui: dict[str, str]) -> None:
    x0, y0, x1, y1 = box
    draw.rounded_rectangle(box, radius=20, fill="#ECFDF5", outline="#B7E4CC", width=2)
    draw.rounded_rectangle((x0 + 26, y0 + 26, x0 + 76, y0 + 76), radius=14, fill=COLORS["teal"])
    draw.rectangle((x0 + 40, y0 + 51, x0 + 62, y0 + 68), fill="white")
    draw.arc((x0 + 40, y0 + 34, x0 + 62, y0 + 62), 180, 360, fill="white", width=4)
    draw.text((x0 + 98, y0 + 24), ui["warning"], font=font(27, "bold"), fill=COLORS["ink"])
    draw.text((x0 + 98, y0 + 60), "AUTH TLS · PBSZ 0 · PROT P", font=font(22, "mono"), fill=COLORS["teal"])


def draw_settings_modal(
    draw: ImageDraw.ImageDraw,
    img: Image.Image,
    box: tuple[int, int, int, int],
    dim_box: tuple[int, int, int, int],
    ui: dict[str, str],
) -> None:
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    overlay_draw = ImageDraw.Draw(overlay)
    overlay_draw.rounded_rectangle(dim_box, radius=30, fill=(8, 14, 26, 72))
    img.alpha_composite(overlay)
    shadowed_rect(img, box, 28, "#FFFFFF", shadow_alpha=80, shadow_radius=42, offset=(0, 20))
    x0, y0, x1, _ = box
    draw = ImageDraw.Draw(img)
    draw.text((x0 + 46, y0 + 40), ui["settings"], font=font(39, "bold"), fill=COLORS["ink"])
    rows = [
        (ui["appearance"], "System / Light / Dark"),
        (ui["language"], "English / Tiếng Việt"),
        (ui["sync"], "On"),
    ]
    y = y0 + 116
    for label, value in rows:
        draw.rounded_rectangle((x0 + 38, y, x1 - 38, y + 76), radius=16, fill="#F7FAFC", outline="#E2E8F0", width=2)
        draw.text((x0 + 64, y + 23), label, font=font(25, "bold"), fill=COLORS["ink"])
        draw.text((x1 - 300, y + 23), value, font=font(24), fill="#607085")
        y += 92
    draw.text((x0 + 46, y + 12), ui["metadata"], font=font(23), fill=COLORS["muted"])


def draw_arrow(draw: ImageDraw.ImageDraw, start: tuple[int, int], end: tuple[int, int], fill: str, width: int) -> None:
    draw.line((*start, *end), fill=fill, width=width)
    angle = math.atan2(end[1] - start[1], end[0] - start[0])
    length = width * 3.0
    left = (end[0] - length * math.cos(angle - math.pi / 6), end[1] - length * math.sin(angle - math.pi / 6))
    right = (end[0] - length * math.cos(angle + math.pi / 6), end[1] - length * math.sin(angle + math.pi / 6))
    draw.polygon([end, left, right], fill=fill)


def draw_app_window(img: Image.Image, box: tuple[int, int, int, int], ui: dict[str, str], mode: str) -> None:
    x0, y0, x1, y1 = box
    shadowed_rect(img, box, 30, "#FFFFFF", shadow_alpha=55, shadow_radius=40, offset=(0, 22))
    draw = ImageDraw.Draw(img)

    title_h = 74
    draw.rounded_rectangle((x0, y0, x1, y0 + title_h + 28), radius=30, fill="#F4F7FA")
    draw.rectangle((x0, y0 + title_h - 8, x1, y0 + title_h + 28), fill="#F4F7FA")
    for i, c in enumerate(["#FF5F57", "#FFBD2E", "#28C840"]):
        draw.ellipse((x0 + 34 + i * 34, y0 + 28, x0 + 54 + i * 34, y0 + 48), fill=c)
    icon = load_icon(42)
    img.alpha_composite(icon, (x0 + 140, y0 + 16))
    draw.text((x0 + 192, y0 + 24), "XConnectFTP", font=font(24, "bold"), fill=COLORS["ink"])

    sidebar_w = 376
    footer_h = 114
    toolbar_h = 104
    body_y = y0 + title_h
    draw_sidebar(draw, (x0, body_y, x0 + sidebar_w, y1 - footer_h), ui, mode)
    draw.line((x0 + sidebar_w, body_y, x0 + sidebar_w, y1 - footer_h), fill="#DCE5EE", width=2)

    main_x = x0 + sidebar_w
    draw_toolbar(draw, (main_x, body_y, x1, body_y + toolbar_h), ui, mode)
    content_y = body_y + toolbar_h
    gap = 26
    pane_w = (x1 - main_x - gap - 40) // 2
    pane_h = y1 - footer_h - content_y - 28
    left_box = (main_x + 26, content_y + 16, main_x + 26 + pane_w, content_y + 16 + pane_h)
    right_box = (left_box[2] + gap, left_box[1], left_box[2] + gap + pane_w, left_box[3])

    search_value = "assets" if mode == "search" else ""
    remote_search = "release" if mode == "search" else ""
    local_selected = {1, 3} if mode in {"drag", "transfer"} else ({1} if mode == "search" else set())
    remote_selected = {3} if mode in {"drag", "transfer"} else set()
    draw_table(draw, left_box, ui["local"], LOCAL_ROWS, ui["search"], search_value, local_selected, mode == "search")
    draw_table(draw, right_box, ui["remote"], REMOTE_ROWS, ui["search"], remote_search, remote_selected, mode == "search")

    if mode == "drag":
        draw_arrow(draw, (left_box[2] + 14, left_box[1] + 346), (right_box[0] - 14, right_box[1] + 346), COLORS["blue"], 16)
        draw_pill(
            draw,
            (left_box[2] - 122, left_box[1] + 278, right_box[0] + 122, left_box[1] + 338),
            ui["shortcuts"],
            "#FFFFFF",
            COLORS["blue"],
            25,
        )
        draw_context_menu(draw, right_box[0] + 84, right_box[1] + 228, ui)

    if mode == "security":
        draw_security_banner(draw, (main_x + 64, content_y + 40, x1 - 64, content_y + 138), ui)

    draw_transfer_footer(draw, (main_x, y1 - footer_h, x1, y1), ui, mode == "transfer")

    if mode == "settings":
        draw_settings_modal(draw, img, (x0 + 705, y0 + 245, x1 - 410, y1 - 210), box, ui)


def compose(scene: dict[str, str], lang_key: str, size: tuple[int, int]) -> Image.Image:
    data = LANG[lang_key]
    ui = data["ui"]
    w, h = size
    img = gradient_background(size)
    draw = ImageDraw.Draw(img)

    margin = int(w * 0.08)
    top = int(h * 0.07)
    icon_size = int(h * 0.085)
    img.alpha_composite(load_icon(icon_size), (margin, top))
    draw.text((margin + icon_size + 24, top + 10), data["brand"], font=font(int(h * 0.035), "bold"), fill=COLORS["ink"])
    draw.text((margin + icon_size + 26, top + int(h * 0.052)), data["kicker"], font=font(int(h * 0.021)), fill=COLORS["muted"])

    title_size = int(h * 0.058)
    subtitle_size = int(h * 0.027)
    title_y = top + icon_size + int(h * 0.04)
    title_bottom = draw_wrapped(
        draw,
        (margin, title_y),
        scene["title"],
        font(title_size, "bold"),
        COLORS["ink"],
        int(w * 0.80),
        int(h * 0.012),
    )
    subtitle_y = title_bottom + int(h * 0.018)
    subtitle_bottom = draw_wrapped(
        draw,
        (margin, subtitle_y),
        scene["subtitle"],
        font(subtitle_size),
        COLORS["muted"],
        int(w * 0.70),
        int(h * 0.012),
    )

    min_window_top = subtitle_bottom + int(h * 0.055)
    if size == SCREENSHOT_SIZE:
        window_box = (int(w * 0.08), max(int(h * 0.38), min_window_top), int(w * 0.92), int(h * 0.90))
    else:
        window_box = (int(w * 0.07), max(int(h * 0.35), min_window_top), int(w * 0.93), int(h * 0.93))
    draw_app_window(img, window_box, ui, scene["mode"])

    return img.convert("RGB")


def write_screenshots() -> None:
    for lang_key, data in LANG.items():
        target = OUT / lang_key / "screenshots" / "mac-2880x1800"
        target.mkdir(parents=True, exist_ok=True)
        for index, scene in enumerate(data["screens"], start=1):
            img = compose(scene, lang_key, SCREENSHOT_SIZE)
            slug = scene["slug"]
            slug_parts = slug.split("-", 1)
            if slug_parts[0].isdigit() and len(slug_parts) == 2:
                slug = slug_parts[1]
            path = target / f"{index:02d}-{slug}.png"
            img.save(path, optimize=True)
            print(f"wrote {path.relative_to(ROOT)}")


def zoom_frame(frame: np.ndarray, progress: float) -> np.ndarray:
    h, w = frame.shape[:2]
    scale = 1.02 + 0.035 * progress
    nw, nh = int(w / scale), int(h / scale)
    x0 = int((w - nw) * (0.45 + 0.1 * progress))
    y0 = int((h - nh) * (0.52 - 0.08 * progress))
    crop = frame[y0 : y0 + nh, x0 : x0 + nw]
    return cv2.resize(crop, (w, h), interpolation=cv2.INTER_CUBIC)


def make_preview(lang_key: str) -> None:
    target = OUT / lang_key / "previews" / "mac-1920x1080"
    frames_dir = target / "_frames"
    target.mkdir(parents=True, exist_ok=True)
    frames_dir.mkdir(parents=True, exist_ok=True)

    scene_images = []
    preview_scenes = LANG[lang_key]["screens"][:6]
    for idx, scene in enumerate(preview_scenes, start=1):
        img = compose(scene, lang_key, PREVIEW_SIZE)
        frame_path = frames_dir / f"scene-{idx:02d}.png"
        img.save(frame_path, optimize=True)
        scene_images.append(cv2.cvtColor(np.array(img), cv2.COLOR_RGB2BGR))

    source_path = target / f"XConnectFTP-preview-{lang_key}-source.mp4"
    final_path = target / f"XConnectFTP-preview-{lang_key}.m4v"
    writer = cv2.VideoWriter(
        str(source_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        FPS,
        PREVIEW_SIZE,
    )
    if not writer.isOpened():
        raise RuntimeError("Could not open OpenCV video writer for preview source")

    frames_per_scene = int(FPS * SEGMENT_SECONDS)
    fade_frames = int(FPS * 0.35)
    for scene_idx, base in enumerate(scene_images):
        next_base = scene_images[scene_idx + 1] if scene_idx + 1 < len(scene_images) else None
        for frame_idx in range(frames_per_scene):
            progress = frame_idx / max(frames_per_scene - 1, 1)
            frame = zoom_frame(base, progress)
            if next_base is not None and frame_idx >= frames_per_scene - fade_frames:
                alpha = (frame_idx - (frames_per_scene - fade_frames)) / max(fade_frames - 1, 1)
                next_frame = zoom_frame(next_base, 0.0)
                frame = cv2.addWeighted(frame, 1 - alpha, next_frame, alpha, 0)
            writer.write(frame)
    writer.release()

    avconvert = shutil.which("avconvert")
    if avconvert:
        subprocess.run(
            [
                avconvert,
                "--source",
                str(source_path),
                "--preset",
                "Preset1920x1080",
                "--output",
                str(final_path),
                "--replace",
            ],
            check=True,
        )
        source_path.unlink(missing_ok=True)
        print(f"wrote {final_path.relative_to(ROOT)}")
    else:
        print(f"wrote {source_path.relative_to(ROOT)}")

    if not final_path.exists():
        raise FileNotFoundError(f"Preview was not created: {final_path}")

    poster_path = target / f"XConnectFTP-preview-{lang_key}-poster.png"
    poster = compose(LANG[lang_key]["screens"][0], lang_key, PREVIEW_SIZE)
    poster.save(poster_path, optimize=True)
    if not poster_path.exists():
        raise FileNotFoundError(f"Poster frame was not created: {poster_path}")
    shutil.rmtree(frames_dir, ignore_errors=True)


def write_readme() -> None:
    readme = OUT / "README.md"
    readme.write_text(
        """# XConnectFTP App Store Assets - 2026-06-17

Generated by `scripts/generate-app-store-assets.py`.

## Contents

- `en/screenshots/mac-2880x1800/`: 7 English Mac App Store screenshots.
- `vi/screenshots/mac-2880x1800/`: 7 Vietnamese Mac App Store screenshots.
- `en/previews/mac-1920x1080/`: English app preview video and poster frame.
- `vi/previews/mac-1920x1080/`: Vietnamese app preview video and poster frame.

## Specs Used

- Mac screenshots: PNG, 2880 x 1800, 16:10.
- Mac app previews: 1920 x 1080 landscape, about 18 seconds.

Apple reference:

- https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
- https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/
""",
        encoding="utf-8",
    )


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    write_screenshots()
    for lang_key in LANG:
        make_preview(lang_key)
    write_readme()
    print(f"done: {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
