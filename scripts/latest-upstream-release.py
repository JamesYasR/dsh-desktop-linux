#!/usr/bin/env python3
"""从 stdin 的上游 tag 列表中选择最新的 RC 或正式版；没有匹配时输出空行。"""

import re
import sys


RELEASE_TAG = re.compile(
    r"dsh-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-rc\.(0|[1-9][0-9]*))?"
)


def release_key(tag):
    match = RELEASE_TAG.fullmatch(tag)
    if match is None:
        return None
    major, minor, patch, rc = match.groups()
    # 同一主/次/补丁版本下：rc.10 > rc.9，正式版 > 所有 RC。
    return (int(major), int(minor), int(patch), rc is None, int(rc or 0))


def latest_release(tags):
    releases = []
    for tag in tags:
        tag = tag.strip()
        key = release_key(tag)
        if key is not None:
            releases.append((key, tag))
    return max(releases)[1] if releases else ""


if __name__ == "__main__":
    print(latest_release(sys.stdin))
