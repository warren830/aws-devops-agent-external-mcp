"""Tests for cn_inventory ARN parsing and source merging.

Run: python3 src/test_cn_inventory.py

Every ARN below was observed in a real aws-cn account during the 2026-07-28
inventory spike, including the two that exposed the original parsing bug:
CloudWatch log groups (":" then "/") and Secrets Manager secrets (":" then "/").
"""

import sys

from cn_inventory import (
    _collect_resource_explorer,
    _matches,
    _merge,
    _parse_arn,
    _summarize,
    collect_inventory,
)

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


def test_merge_does_not_mutate_input() -> None:
    """Regression: _merge used to append into the caller's own list/dict objects.

    That corrupted the caller's data and, worse, leaked state between assertions
    in this very file — a later _merge call saw 'tagging' already present in
    re_row['sources'] from an earlier one.
    """
    print("\ntest_merge_does_not_mutate_input — 输入不被就地修改")
    row_a = {"arn": "x", "service": "s", "type": "t", "region": "r", "account": "1",
             "tags": {"A": "1"}, "last_reported": "", "sources": ["resource_explorer"]}
    row_b = {"arn": "x", "service": "s", "type": "t", "region": "r", "account": "1",
             "tags": {"B": "2"}, "last_reported": "", "sources": ["tagging"]}

    _merge([row_a], [row_b])
    check("调用方的 sources 未被改动", row_a["sources"], ["resource_explorer"])
    check("调用方的 tags 未被改动", row_a["tags"], {"A": "1"})

    merged = _merge([row_a], [row_b])[0]
    check("合并结果仍包含两个源", sorted(merged["sources"]), ["resource_explorer", "tagging"])
    check("合并结果 tags 取并集", merged["tags"], {"A": "1", "B": "2"})


def test_parse_arn_edge_cases() -> None:
    """ARNs whose resource segment starts with a separator, or embeds a path."""
    print("\ntest_parse_arn_edge_cases — 分隔符边界")
    # Regression: cut at position 0 left rtype empty -> type 'apigateway:'.
    check(
        "resource 段以 / 开头",
        _parse_arn("arn:aws-cn:apigateway:cn-north-1::/restapis/a1b2c3")["type"],
        "apigateway",
    )
    # Regression: bucket name leaked into the type as 's3:my-bucket'.
    check(
        "S3 对象 key 不进 type",
        _parse_arn("arn:aws-cn:s3:::my-bucket/key/part")["type"],
        "s3",
    )
    check(
        "S3 对象 name 保留完整路径",
        _parse_arn("arn:aws-cn:s3:::my-bucket/key/part")["name"],
        "my-bucket/key/part",
    )


def test_matches_resource_type_is_exact() -> None:
    """Regression: substring matching made ec2:vpc also select vpc-endpoint etc.

    entrypoint.py advertises resource_type="ec2:vpc" to the agent, so an
    over-matching filter makes the agent report VPC counts that silently
    include endpoints, peering connections and flow logs.
    """
    print("\ntest_matches_resource_type_is_exact — 类型过滤精确匹配")
    def row(t):
        return {"arn": t, "service": "ec2", "type": t, "region": "cn-north-1",
                "account": "1", "tags": {}, "last_reported": "", "sources": ["re"]}
    rows = [row(t) for t in ("ec2:vpc", "ec2:vpc-endpoint",
                             "ec2:vpc-peering-connection", "ec2:vpc-flow-log")]
    hit = [r["type"] for r in rows if _matches(r, None, "ec2:vpc", None, None)]
    check("ec2:vpc 只命中自身", hit, ["ec2:vpc"])

    # A trailing "*" opts into the old prefix behaviour explicitly.
    hit2 = sorted(r["type"] for r in rows if _matches(r, None, "ec2:vpc*", None, None))
    check("ec2:vpc* 命中全部 4 个", len(hit2), 4)


def test_summarize_is_bounded() -> None:
    """The module's stated purpose is a bounded payload; stacks were uncapped."""
    print("\ntest_summarize_is_bounded — summary 档有界")
    rows = [{"arn": f"a{i}", "service": f"svc{i}", "type": f"t{i}", "region": f"r{i}",
             "account": "1", "tags": {"aws:cloudformation:stack-name": f"stack-{i}"},
             "last_reported": "", "sources": ["t"]} for i in range(300)]
    s = _summarize(rows)
    check("总数仍精确", s["total_resources"], 300)
    for field in ("by_service", "by_resource_type", "by_region",
                  "cloudformation_stacks", "tag_keys"):
        n = len(s[field])
        check(f"{field} 有上限 (实际 {n})", n <= 60, True)


def test_collect_handles_malformed_items() -> None:
    """A single bad item must not take down the whole tool.

    Both collectors used to catch only ClientError/BotoCoreError, so a KeyError
    from item["Arn"] escaped to entrypoint.py's blanket handler — losing the
    coverage report and the other source's rows.
    """
    print("\ntest_collect_handles_malformed_items — 畸形数据不炸整个工具")

    class BadRE:
        def search(self, **kw):
            return {"Resources": [{"NoArnHere": True}],
                    "Count": {"TotalResources": 1, "Complete": True}}

    rows, err = _collect_resource_explorer(_FakeSession(re_client=BadRE()), "cn-north-1")
    check("不抛异常", True, True)
    check("返回空行而非崩溃", rows, [])
    check("报告了错误", err is not None, True)


def test_truncation_is_reported() -> None:
    """Resource Explorer caps an empty query at 1000 results and says so via
    Count.Complete. Ignoring that field is silent truncation."""
    print("\ntest_truncation_is_reported — RE 截断必须上报")

    class CappedRE:
        def search(self, **kw):
            return {"Resources": [{"Arn": "arn:aws-cn:s3:::b", "Service": "s3",
                                   "ResourceType": "s3:bucket", "Region": "cn-north-1",
                                   "OwningAccountId": "1", "Properties": []}],
                    "Count": {"TotalResources": 5000, "Complete": False}}

    rows, err = _collect_resource_explorer(_FakeSession(re_client=CappedRE()), "cn-north-1")
    check("拿到了数据", len(rows), 1)
    check("截断被报告", err is not None and "1,000" in err or "1000" in str(err), True)


def test_completeness_distinguishes_degradation() -> None:
    """A status that is always PARTIAL carries no signal.

    The production setup (cross-region AGGREGATOR) inherently has a tag caveat,
    so it must not be reported the same way as a genuinely degraded run.
    """
    print("\ntest_completeness_distinguishes_degradation — PARTIAL 要有区分度")

    healthy = collect_inventory(session=_FakeSession(agg=True), query_region="cn-northwest-1")
    degraded = collect_inventory(session=_FakeSession(agg=False), query_region="cn-northwest-1")

    check("AGGREGATOR 不报 PARTIAL", healthy["completeness"].startswith("PARTIAL"), False)
    check("AGGREGATOR 仍列出标签注意事项", len(healthy["coverage"]["caveats"]) > 0, True)
    check("LOCAL 索引报 PARTIAL", degraded["completeness"].startswith("PARTIAL"), True)
    check("LOCAL 索引有 blind_spots", len(degraded["coverage"]["blind_spots"]) > 0, True)


def test_input_validation_precedes_api_calls() -> None:
    """An unknown mode used to be rejected only after both full sweeps ran."""
    print("\ntest_input_validation_precedes_api_calls — 参数先校验后调用")
    sess = _FakeSession(agg=True, record=True)
    r = collect_inventory(mode="bogus", session=sess, query_region="cn-northwest-1")
    check("非法 mode 被拒绝", "error" in r, True)
    check("拒绝前未调用任何 API", sess.calls, [])

    sess2 = _FakeSession(agg=True, record=True)
    r2 = collect_inventory(mode="list", limit=-1, session=sess2, query_region="cn-northwest-1")
    check("负数 limit 被拒绝", "error" in r2, True)


class _FakeClient:
    """Minimal stand-in for both AWS clients used by the module."""

    def __init__(self, agg=True, rows=None, record=None):
        self.agg, self.rows, self.record = agg, rows or [], record

    def get_index(self):
        return {"Type": "AGGREGATOR" if self.agg else "LOCAL", "State": "ACTIVE",
                "ReplicatingFrom": ["cn-north-1"] if self.agg else []}

    def get_default_view(self):
        return {"ViewArn": "v"}

    def get_view(self, ViewArn):
        return {"View": {"IncludedProperties": [{"Name": "tags"}]}}

    def search(self, **kw):
        if self.record is not None:
            self.record.append("RE.search")
        return {"Resources": self.rows, "Count": {"TotalResources": len(self.rows),
                                                 "Complete": True}}

    def get_resources(self, **kw):
        if self.record is not None:
            self.record.append("Tagging.get_resources")
        return {"ResourceTagMappingList": []}


class _FakeSession:
    def __init__(self, agg=True, re_client=None, record=False):
        self.agg, self.re_client = agg, re_client
        self.region_name = "cn-northwest-1"
        self.calls = [] if record else None

    def client(self, name, **kw):
        if name == "resource-explorer-2" and self.re_client is not None:
            return self.re_client
        return _FakeClient(agg=self.agg, record=self.calls)


if __name__ == "__main__":
    test_parse_arn()
    test_parse_arn_edge_cases()
    test_merge()
    test_merge_does_not_mutate_input()
    test_matches_resource_type_is_exact()
    test_summarize()
    test_summarize_is_bounded()
    test_collect_handles_malformed_items()
    test_truncation_is_reported()
    test_completeness_distinguishes_degradation()
    test_input_validation_precedes_api_calls()
    print(f"\n{'='*50}\n通过 {PASS} / 失败 {FAIL}")
    sys.exit(1 if FAIL else 0)
