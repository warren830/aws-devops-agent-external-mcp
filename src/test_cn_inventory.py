"""Tests for cn_inventory ARN parsing and source merging.

Run: python3 src/test_cn_inventory.py

Every ARN below was observed in a real aws-cn account during the 2026-07-28
inventory spike, including the two that exposed the original parsing bug:
CloudWatch log groups (":" then "/") and Secrets Manager secrets (":" then "/").
"""

import sys

from cn_inventory import _merge, _parse_arn, _summarize

PASS = FAIL = 0


def check(label: str, got, want) -> None:
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  ✅ {label}")
    else:
        FAIL += 1
        print(f"  ❌ {label}\n       got  {got!r}\n       want {want!r}")


def test_parse_arn() -> None:
    print("test_parse_arn — 真实 aws-cn ARN")

    # Regression: ":" must be tried before "/", or type keeps a trailing colon.
    check(
        "log group (: 后跟 /)",
        _parse_arn("arn:aws-cn:logs:cn-north-1:107422471498:log-group:/aws/eks/bjs-web/application")["type"],
        "logs:log-group",
    )
    # Regression: name contained a "/", which used to leak into the type.
    check(
        "secret (: 后跟 /)",
        _parse_arn("arn:aws-cn:secretsmanager:cn-north-1:107422471498:secret:bjs-todo-db/master-802jNs")["type"],
        "secretsmanager:secret",
    )
    check(
        "vpc (只有 /)",
        _parse_arn("arn:aws-cn:ec2:cn-north-1:284567523170:vpc/vpc-046d31d4731d50516")["type"],
        "ec2:vpc",
    )
    # Regression: "/" comes before ":" here (task-definition/family:revision).
    # A fixed "': ' before '/'" rule produced type "ecs:task-definition/etl" and
    # name "3". The separator that appears FIRST is the type separator.
    check(
        "ecs task-definition (/ 在 : 之前)",
        _parse_arn("arn:aws-cn:ecs:cn-northwest-1:1:task-definition/etl-worker:3")["type"],
        "ecs:task-definition",
    )
    check(
        "ecs task-definition 名字含 revision",
        _parse_arn("arn:aws-cn:ecs:cn-northwest-1:1:task-definition/etl-worker:3")["name"],
        "etl-worker:3",
    )
    check(
        "lambda 版本 (: 在 / 之前)",
        _parse_arn("arn:aws-cn:lambda:cn-north-1:1:function:my-fn:PROD")["type"],
        "lambda:function",
    )
    check(
        "iam role 带路径",
        _parse_arn("arn:aws-cn:iam::107422471498:role/service-role/my-role")["type"],
        "iam:role",
    )
    check(
        "s3 bucket (无分隔符)",
        _parse_arn("arn:aws-cn:s3:::my-bucket")["type"],
        "s3",
    )
    check(
        "iam 是 global",
        _parse_arn("arn:aws-cn:iam::107422471498:role/foo")["region"],
        "global",
    )
    check(
        "分区解析",
        _parse_arn("arn:aws-cn:ec2:cn-north-1:1:vpc/vpc-a")["partition"],
        "aws-cn",
    )
    check(
        "名字保留内部斜杠",
        _parse_arn("arn:aws-cn:logs:cn-north-1:1:log-group:/aws/lambda/foo")["name"],
        "/aws/lambda/foo",
    )
    check(
        "畸形 ARN 不抛异常",
        _parse_arn("not-an-arn")["type"],
        "unknown",
    )


def test_merge() -> None:
    print("\ntest_merge — 源合并")
    arn = "arn:aws-cn:logs:cn-north-1:1:log-group:/aws/foo"

    re_row = {
        "arn": arn, "service": "logs", "type": "logs:log-group",
        "region": "cn-north-1", "account": "1", "tags": {},
        "last_reported": "2026-07-28", "sources": ["resource_explorer"],
    }
    tag_row = {
        "arn": arn, "service": "logs", "type": "logs:log-group",
        "region": "cn-north-1", "account": "1", "tags": {"Project": "bjs-web"},
        "last_reported": "", "sources": ["tagging"],
    }

    merged = _merge([re_row], [tag_row])
    check("同 ARN 去重成 1 条", len(merged), 1)
    check("两个源都记录下来", sorted(merged[0]["sources"]), ["resource_explorer", "tagging"])
    check("Tagging 的标签没被 RE 的空标签覆盖", merged[0]["tags"], {"Project": "bjs-web"})
    check("RE 的 last_reported 保留", merged[0]["last_reported"], "2026-07-28")

    # RE type wins: it is the AWS-canonical value. Feed a junk type from the
    # other source and confirm it does not overwrite.
    junk = dict(tag_row, type="logs:log-group:junk:longer")
    check(
        "RE 的规范 type 不被更长的杂值覆盖",
        _merge([re_row], [junk])[0]["type"],
        "logs:log-group",
    )

    # Resource only one source can see must survive.
    only_tag = dict(tag_row, arn="arn:aws-cn:s3:::solo-bucket", type="s3")
    check("单源独有资源保留", len(_merge([re_row], [tag_row, only_tag])), 2)


def test_summarize() -> None:
    print("\ntest_summarize — 汇总")
    rows = [
        {"arn": "a", "service": "ec2", "type": "ec2:vpc", "region": "cn-north-1",
         "account": "1", "tags": {"aws:cloudformation:stack-name": "S1"},
         "last_reported": "", "sources": ["resource_explorer"]},
        {"arn": "b", "service": "ec2", "type": "ec2:subnet", "region": "cn-north-1",
         "account": "1", "tags": {"aws:cloudformation:stack-name": "S1", "Name": "n"},
         "last_reported": "", "sources": ["tagging"]},
        {"arn": "c", "service": "s3", "type": "s3", "region": "global",
         "account": "1", "tags": {}, "last_reported": "", "sources": ["tagging"]},
    ]
    s = _summarize(rows)
    check("总数", s["total_resources"], 3)
    check("按服务", s["by_service"], {"ec2": 2, "s3": 1})
    check("按区域", s["by_region"], {"cn-north-1": 2, "global": 1})
    check("CFN 栈聚合", s["cloudformation_stacks"], {"S1": 2})
    check("标签 key 计数", s["tag_keys"]["aws:cloudformation:stack-name"], 2)
    check("源重叠统计", s["source_overlap"], {"resource_explorer": 1, "tagging": 2})


if __name__ == "__main__":
    test_parse_arn()
    test_merge()
    test_summarize()
    print(f"\n{'='*50}\n通过 {PASS} / 失败 {FAIL}")
    sys.exit(1 if FAIL else 0)
