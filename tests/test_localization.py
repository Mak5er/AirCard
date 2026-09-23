import base64
import io
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import aircard
import aircard_backend


# 使用真实的小图片和中文文件名，让测试覆盖文件读取、JSON 编解码及主题资源生成。
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


class ChineseLocalizationTests(unittest.TestCase):
    def test_inspect_theme_with_chinese_path_over_backend_protocol(self):
        # 启动实际后端进程，确认中文主题名和预览图片能通过标准输出完整交给界面。
        with tempfile.TemporaryDirectory() as directory:
            theme = self.make_theme(Path(directory))
            process = subprocess.run(
                [sys.executable, str(Path(aircard_backend.__file__)),
                 "--inspect-passthm", str(theme)],
                check=True, capture_output=True, text=True,
            )
        response = json.loads(process.stdout)
        self.assertTrue(response["ok"])
        self.assertEqual(response["name"], "中文主题")
        self.assertEqual(response["detected_version"], "TelephonyUI-10")
        self.assertEqual(set(response["keys_preview"]), set("0123456789"))
        preview = response["keys_preview"]["5"]
        self.assertTrue(preview.startswith("data:image/png;base64,"))
        self.assertEqual(base64.b64decode(preview.split(",", 1)[1]), PNG)

    def test_chinese_target_keeps_machine_filenames_and_payloads(self):
        # 中文界面不能把系统缓存使用的 zh、other、white 或 bold 等标识翻译掉。
        with tempfile.TemporaryDirectory() as directory:
            theme = self.make_theme(Path(directory))
            items = aircard_backend.parse_passthm_archive(
                str(theme), "TelephonyUI-10", "zh", "bold"
            )
        self.assertGreater(len(items), 10)
        self.assertEqual({target for target, _, _ in items},
                         {"/var/mobile/Library/Caches/TelephonyUI-10"})
        self.assertEqual({leaf.split("-")[0] for _, leaf, _ in items}, {"zh", "other"})
        for _, leaf, payload in items:
            self.assertTrue(leaf.endswith("--white-bold.png"), leaf)
            self.assertEqual(payload, PNG)
        leaves = {leaf for _, leaf, _ in items}
        for digit in range(10):
            self.assertIn(f"zh-{digit}---white-bold.png", leaves)

    def test_chinese_progress_keeps_numeric_progress_and_success_type(self):
        # 模拟设备写入并触发进度回调，确认翻译不影响 Swift 端依赖的状态与计数。
        def write_batch(udid, target, files, **kwargs):
            kwargs["progress_callback"]({"index": 1, "leaf": files[0][0]})
            return True

        with tempfile.TemporaryDirectory() as directory:
            theme = self.make_theme(Path(directory))
            output = io.StringIO()
            with patch.object(aircard_backend, "write_files_batch", side_effect=write_batch), redirect_stdout(output):
                result = aircard_backend.cmd_flash_passthm(
                    "test-device", str(theme), "TelephonyUI-10", "zh", "regular"
                )
        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertTrue(result)
        self.assertEqual(messages[-1]["type"], "success")
        self.assertEqual(messages[-1]["step"], messages[-1]["total"])
        self.assertIn("中文主题", messages[-1]["message"])
        self.assertTrue(any(message.get("leaf", "").startswith("zh-") for message in messages))
        for message in messages:
            self.assertRegex(message["message"], r"[\u4e00-\u9fff]")
            self.assertIsInstance(message["step"], int)
            self.assertIsInstance(message["total"], int)

    def test_failed_fallback_reports_chinese_error_without_success(self):
        # 强制批量和单文件写入都失败，确保中文错误不会被当作成功消息。
        with tempfile.TemporaryDirectory() as directory:
            theme = self.make_theme(Path(directory))
            output = io.StringIO()
            with (
                patch.object(aircard_backend, "write_files_batch", return_value=False),
                patch.object(aircard_backend, "write_file", return_value=False),
                patch.object(aircard_backend.time, "sleep"),
                redirect_stdout(output),
            ):
                result = aircard_backend.cmd_flash_passthm(
                    "test-device", str(theme), "TelephonyUI-10", "zh", "regular"
                )
        messages = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(result)
        self.assertEqual(messages[-1]["type"], "error")
        self.assertRegex(messages[-1]["message"], r"[\u4e00-\u9fff]")
        self.assertTrue(any(message["type"] == "warning" for message in messages))
        self.assertFalse(any(message["type"] == "success" for message in messages))

    def test_missing_theme_reports_chinese_error(self):
        # 通过不存在的中文路径触发真实错误分支，保留 ok/error 协议供调用方判断。
        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            with redirect_stdout(output):
                result = aircard_backend.cmd_flash_passthm(
                    "test-device", str(Path(directory) / "不存在.passthm")
                )
        self.assertFalse(result)
        response = json.loads(output.getvalue())
        self.assertFalse(response["ok"])
        self.assertRegex(response["error"], r"[\u4e00-\u9fff]")

    def test_cli_without_device_shows_chinese_instructions(self):
        # 未连接设备时仅验证命令行提示和退出码，不执行任何设备写入。
        output = io.StringIO()
        with patch.object(aircard, "get_connected_device", return_value=None), redirect_stdout(output):
            with self.assertRaises(SystemExit) as failure:
                aircard.main()
        self.assertEqual(failure.exception.code, 1)
        self.assertIn("未找到 iPhone", output.getvalue())
        self.assertIn("USB", output.getvalue())

    @staticmethod
    def make_theme(directory):
        # 在临时目录末尾统一生成主题，避免测试创建用户资产或依赖本机已有主题。
        theme = directory / "中文主题.passthm"
        with zipfile.ZipFile(theme, "w") as archive:
            archive.writestr("TelephonyUI-10/_big", b"")
            for digit in range(10):
                archive.writestr(f"TelephonyUI-10/en-{digit}---white.png", PNG)
        return theme


if __name__ == "__main__":
    unittest.main()
