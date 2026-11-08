"""直播线路选择回归：用明确的单元测试夹具，不请求网络、不包含真实签名 URL。"""
import json
from pathlib import Path
import subprocess
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "DouDuo/DouyinFeedView.swift"
HELPER = SOURCE.read_text().split('static let requestJS = #"""', 1)[1].split('    const req =', 1)[0]


def compatible(sdk, flv):
    room = {"live_core_sdk_data": {"pull_data": {"stream_data": json.dumps(sdk)}}, "flv_pull_url": flv}
    code = "const parse=t=>{try{return JSON.parse(t)}catch{return null}};" + HELPER
    code += "console.log(JSON.stringify(compatibleLiveFLV(JSON.parse(process.argv[1]))));"
    return json.loads(subprocess.check_output(["node", "-e", code, json.dumps(room)], text=True))


def stream(url, codec="h264", bitrate=1500000, encrypted=False):
    return {"flv": url, "enableEncryption": encrypted,
            "sdk_params": json.dumps({"VCodec": codec, "vbitrate": bitrate})}


class LiveSourceTests(unittest.TestCase):
    url = "https://example.invalid/test.flv?codec=avc&signature=fixture"

    def test_accept_explicit_video_avc_only(self):
        self.assertEqual(compatible({"data": {"hd": {"main": stream(self.url)}}}, {"HD1": self.url}), {"HD1": self.url})

    def test_hevc_does_not_spend_seconds_in_unsupported_flv(self):
        self.assertEqual(compatible({"data": {"hd": {"main": stream(self.url, "h265")}}}, {"HD1": self.url}), {})

    def test_audio_only_codec_cannot_mark_video_as_compatible(self):
        sdk = {"data": {"ao": {"main": stream(self.url, bitrate=0)},
                        "origin": {"main": stream(self.url, "h265")}}}
        self.assertEqual(compatible(sdk, {"FULL_HD1": self.url}), {})

    def test_encrypted_stream_is_never_used_as_compatibility_evidence(self):
        self.assertEqual(compatible({"data": {"hd": {"main": stream(self.url, encrypted=True)}}}, {"HD1": self.url}), {})

    def test_urls_must_match_exactly_including_parameters(self):
        self.assertEqual(compatible({"data": {"hd": {"main": stream(self.url)}}}, {"HD1": self.url.replace("codec=avc", "codec=hevc")}), {})

    def test_missing_sdk_keeps_hls_fallback(self):
        self.assertEqual(compatible({}, {"HD1": self.url}), {})


if __name__ == "__main__":
    unittest.main()
