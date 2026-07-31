"""
Batch resource inventory for AWS China partition accounts.

Why this exists
---------------
AWS DevOps Agent's native resource discovery uses CloudFormation stacks +
Resource Explorer with the agent's own (global partition) credentials, so it
cannot reach aws-cn. This module gives the agent a batch inventory verb that
runs inside the China partition, where the MCP server holds cn credentials.

Why multiple sources
--------------------
Measured on a real cn account (2026-07-28, cn-northwest-1): Resource Explorer
returned 128 resources, Resource Groups Tagging API returned 176, and the
intersection was only 27. They are complementary, not redundant:

  - Resource Explorer  covers resources that carry no tags (logs, kms, ecr,
                       memorydb, xray) and can aggregate across regions.
  - Tagging API        covers tagged resources RE misses (sagemaker, s3, ecs,
                       batch) and returns tags, including the CloudFormation
                       stack lineage tags that RE does not surface.

No single API returns a complete inventory in the China partition. So we query
both and merge by ARN. Partial failures are reported in the payload rather than
swallowed, because an agent that believes it saw everything is worse than an
agent that knows its view is incomplete.

Why the mode parameter
----------------------
Also measured: 151 resources serialize to 44.2 KB, roughly 11k tokens. A
customer estate of a few thousand resources would blow the agent's context
window outright. "summary" is therefore the default, and callers opt into
detail explicitly.
"""

from __future__ import annotations

import collections
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# Tag keys CloudFormation writes onto every resource it creates. These give us
# deployment lineage for free, which is the same signal the agent's native
# CloudFormation-stack discovery relies on.
_CFN_STACK_TAG = "aws:cloudformation:stack-name"

# Tag keys commonly used as a human-readable name.
_NAME_TAG_KEYS = ("Name", "name")


def _parse_arn(arn: str) -> dict[str, str]:
    """Split an ARN into its parts, tolerating both resource-ARN layouts.

    aws-cn ARNs look like:
      arn:aws-cn:logs:cn-north-1:123:log-group:/aws/lambda/foo
      arn:aws-cn:ec2:cn-north-1:123:vpc/vpc-abc
      arn:aws-cn:s3:::my-bucket

      arn:aws-cn:ecs:cn-northwest-1:123:task-definition/etl-worker:3

    The type separator is whichever of ":" or "/" appears FIRST -- neither one
    can be preferred unconditionally, because both orderings occur in real
    aws-cn ARNs:
      "log-group:/aws/lambda/foo"      ":" first, "/" belongs to the name
      "task-definition/etl-worker:3"   "/" first, ":" is the ECS revision
    Preferring ":" outright yields type "task-definition/etl-worker" and name
    "3"; preferring "/" outright yields type "log-group:". Both were observed.
    """
    parts = arn.split(":", 5)
    if len(parts) < 6:
        return {"service": "unknown", "region": "", "account": "", "type": "unknown", "name": arn}

    _, partition, service, region, account, resource = parts

    # Resource segment is "type<sep>name" or a bare name; split at the earliest
    # separator so the remainder (which may contain the other one) stays in name.
    positions = [resource.find(sep) for sep in (":", "/")]
    cut = min((p for p in positions if p != -1), default=-1)
    if cut == -1:
        rtype, name = service, resource
    else:
        rtype, name = resource[:cut], resource[cut + 1:]

    return {
        "partition": partition,
        "service": service,
        "region": region or "global",
        "account": account,
        "type": f"{service}:{rtype}" if rtype != service else service,
        "name": name or resource,
    }


def _probe_coverage(session: boto3.Session, region: str) -> dict:
    """Report what the Resource Explorer index actually covers.

    This exists because the dangerous failure mode is not an exception, it is
    silence. Measured on 2026-07-28: querying a cn region with no index did not
    raise -- Resource Explorer auto-created a LOCAL index and a default view on
    first access, then returned a partial result set with no warning. A LOCAL
    index covers one region and an auto-created view carries no tags, so an
    agent that trusts the payload would report a single-region, untagged view as
    the whole estate.

    So we ask the index what it covers and state the blind spots explicitly,
    rather than inferring health from the absence of an error.
    """
    coverage: dict[str, Any] = {
        "index_type": None,
        "index_state": None,
        "regions_covered": [],
        "tags_from_resource_explorer": False,
        "blind_spots": [],
    }

    try:
        client = session.client("resource-explorer-2", region_name=region)
    except Exception as exc:  # pragma: no cover
        coverage["blind_spots"].append(f"cannot reach Resource Explorer: {exc}")
        return coverage

    try:
        index = client.get_index()
        coverage["index_type"] = index.get("Type")
        coverage["index_state"] = index.get("State")

        if index.get("Type") == "AGGREGATOR":
            coverage["regions_covered"] = sorted({region, *index.get("ReplicatingFrom", [])})
        else:
            coverage["regions_covered"] = [region]
            coverage["blind_spots"].append(
                f"Resource Explorer index in {region} is LOCAL, not AGGREGATOR. Only {region} "
                "is covered; resources in the account's other China regions are MISSING. "
                "Fix: create an index in each region, then "
                "`update-index-type --type AGGREGATOR` on one of them."
            )

        if index.get("State") != "ACTIVE":
            coverage["blind_spots"].append(
                f"index state is {index.get('State')}, not ACTIVE -- results are incomplete "
                "while the index is still building (first build can take hours)."
            )
    except (ClientError, BotoCoreError) as exc:
        coverage["blind_spots"].append(f"could not read index state: {exc}")

    try:
        view_arn = client.get_default_view().get("ViewArn")
        if view_arn:
            props = client.get_view(ViewArn=view_arn)["View"].get("IncludedProperties", [])
            coverage["tags_from_resource_explorer"] = any(p.get("Name") == "tags" for p in props)
        if not coverage["tags_from_resource_explorer"]:
            coverage["blind_spots"].append(
                "default Resource Explorer view does not include the 'tags' property, so "
                "RE-only resources come back untagged. Tags for those resources are "
                "unavailable (the Tagging API cannot see them -- that is why RE found them). "
                "Fix: `update-view --included-properties Name=tags`."
            )
    except (ClientError, BotoCoreError) as exc:
        coverage["blind_spots"].append(f"could not read default view: {exc}")

    return coverage


def _collect_resource_explorer(session: boto3.Session, region: str) -> tuple[list[dict], str | None]:
    """Page through Resource Explorer. Returns (resources, error_message)."""
    try:
        client = session.client("resource-explorer-2", region_name=region)
    except Exception as exc:  # pragma: no cover - client construction rarely fails
        return [], f"could not create resource-explorer-2 client: {exc}"

    out: list[dict] = []
    token: str | None = None
    try:
        while True:
            kwargs: dict[str, Any] = {"QueryString": "", "MaxResults": 100}
            if token:
                kwargs["NextToken"] = token
            page = client.search(**kwargs)

            for item in page.get("Resources", []):
                tags: dict[str, str] = {}
                for prop in item.get("Properties", []):
                    if prop.get("Name") == "tags":
                        for tag in prop.get("Data", []):
                            tags[tag["Key"]] = tag["Value"]
                out.append(
                    {
                        "arn": item["Arn"],
                        "service": item.get("Service", ""),
                        "type": item.get("ResourceType", ""),
                        "region": item.get("Region", ""),
                        "account": item.get("OwningAccountId", ""),
                        "tags": tags,
                        "last_reported": str(item.get("LastReportedAt", "")),
                        "sources": ["resource_explorer"],
                    }
                )

            token = page.get("NextToken")
            if not token:
                break
    except (ClientError, BotoCoreError) as exc:
        code = getattr(exc, "response", {}).get("Error", {}).get("Code", "")
        if code in ("ResourceNotFoundException", "UnauthorizedException", "AccessDeniedException"):
            return out, (
                f"Resource Explorer unavailable ({code}). No index or view in {region}, "
                "or missing permissions. Resources that carry no tags "
                "(CloudWatch log groups, KMS keys, ECR repos) will be MISSING from this result."
            )
        return out, f"Resource Explorer failed: {exc}"

    return out, None


def _collect_tagging(session: boto3.Session, region: str) -> tuple[list[dict], str | None]:
    """Page through Resource Groups Tagging API. Returns (resources, error_message)."""
    try:
        client = session.client("resourcegroupstaggingapi", region_name=region)
    except Exception as exc:  # pragma: no cover
        return [], f"could not create resourcegroupstaggingapi client: {exc}"

    out: list[dict] = []
    token: str | None = None
    try:
        while True:
            kwargs: dict[str, Any] = {"ResourcesPerPage": 100}
            if token:
                kwargs["PaginationToken"] = token
            page = client.get_resources(**kwargs)

            for item in page.get("ResourceTagMappingList", []):
                arn = item["ResourceARN"]
                meta = _parse_arn(arn)
                out.append(
                    {
                        "arn": arn,
                        "service": meta["service"],
                        "type": meta["type"],
                        "region": meta["region"],
                        "account": meta["account"],
                        "tags": {t["Key"]: t["Value"] for t in item.get("Tags", [])},
                        "last_reported": "",
                        "sources": ["tagging"],
                    }
                )

            token = page.get("PaginationToken") or None
            if not token:
                break
    except (ClientError, BotoCoreError) as exc:
        return out, f"Tagging API failed: {exc}"

    return out, None


def _merge(*batches: list[dict]) -> list[dict]:
    """Merge source batches by ARN.

    Batches are merged in the order given, and earlier batches win on scalar
    fields. Callers therefore pass the Resource Explorer batch first, because
    its ResourceType is the AWS-canonical value while the Tagging API path has
    to infer a type from the ARN.

    Conflict rules, chosen from measured behaviour of each source:
      - scalars: first non-empty value wins (RE first). Never compare by
                 length -- a longer string is not a more specific type, it is
                 usually a name that leaked into the type.
      - tags:    union. RE tags are often empty even with the tags property
                 enabled, so Tagging API values must not be overwritten.
      - sources: accumulated, so callers can see which API saw each resource.
    """
    merged: dict[str, dict] = {}
    for batch in batches:
        for res in batch:
            existing = merged.get(res["arn"])
            if existing is None:
                merged[res["arn"]] = dict(res)
                continue

            for key in ("type", "service", "region", "account", "last_reported"):
                if not existing.get(key) and res.get(key):
                    existing[key] = res[key]
            existing["tags"] = {**res.get("tags", {}), **existing.get("tags", {})}
            for src in res["sources"]:
                if src not in existing["sources"]:
                    existing["sources"].append(src)

    return list(merged.values())


def _display_name(res: dict) -> str:
    for key in _NAME_TAG_KEYS:
        if key in res["tags"]:
            return res["tags"][key]
    return _parse_arn(res["arn"])["name"]


def _summarize(resources: list[dict]) -> dict:
    """Counts-only skeleton. This is what keeps the payload inside a context budget."""
    by_service = collections.Counter(r["service"] for r in resources)
    by_type = collections.Counter(r["type"] for r in resources)
    by_region = collections.Counter(r["region"] for r in resources)
    by_source = collections.Counter(tuple(sorted(r["sources"])) for r in resources)

    tag_keys = collections.Counter()
    cfn_stacks = collections.Counter()
    for res in resources:
        for key, value in res["tags"].items():
            tag_keys[key] += 1
            if key == _CFN_STACK_TAG:
                cfn_stacks[value] += 1

    return {
        "total_resources": len(resources),
        "by_region": dict(by_region.most_common()),
        "by_service": dict(by_service.most_common()),
        "by_resource_type": dict(by_type.most_common(40)),
        "cloudformation_stacks": dict(cfn_stacks.most_common()),
        "tag_keys": dict(tag_keys.most_common(30)),
        "source_overlap": {"+".join(k): v for k, v in by_source.most_common()},
    }


def _matches(res: dict, service: str | None, resource_type: str | None,
             region: str | None, tag_key: str | None) -> bool:
    if service and res["service"] != service:
        return False
    if resource_type and resource_type not in res["type"]:
        return False
    if region and res["region"] != region:
        return False
    if tag_key and tag_key not in res["tags"]:
        return False
    return True


def collect_inventory(
    mode: str = "summary",
    service: str | None = None,
    resource_type: str | None = None,
    region_filter: str | None = None,
    tag_key: str | None = None,
    limit: int = 200,
    *,
    session: boto3.Session | None = None,
    query_region: str | None = None,
) -> dict:
    """Return a merged inventory of the account's China-partition resources.

    mode:
      "summary" (default) — counts by service/type/region, CFN stacks, tag keys.
                            Bounded payload regardless of estate size.
      "list"              — one line per resource (arn, name, type, region, tags).
                            Apply filters to keep this bounded.
      "detail"            — full records including every tag.

    query_region: region whose Resource Explorer index to query. If that index
      is an AGGREGATOR, results span every region in the account.
    """
    session = session or boto3.Session()
    query_region = query_region or session.region_name or "cn-northwest-1"

    coverage = _probe_coverage(session, query_region)
    re_rows, re_err = _collect_resource_explorer(session, query_region)
    tag_rows, tag_err = _collect_tagging(session, query_region)

    warnings = [msg for msg in (re_err, tag_err) if msg]
    if re_err and tag_err:
        return {
            "error": "both inventory sources failed; no inventory available",
            "warnings": warnings,
            "coverage": coverage,
        }

    # The Tagging API is per-region by design, so anything the aggregator index
    # pulled in from another region has no Tagging counterpart and will be
    # untagged. Say so, rather than letting the agent read absent tags as
    # "resource has no tags".
    other_regions = [r for r in coverage["regions_covered"] if r != query_region]
    if other_regions:
        coverage["blind_spots"].append(
            f"tags for resources in {', '.join(other_regions)} are incomplete: the Tagging API "
            f"was only queried in {query_region}. Re-run with query_region set to those regions "
            "if tag coverage matters."
        )

    resources = _merge(re_rows, tag_rows)
    filtered = [
        r for r in resources
        if _matches(r, service, resource_type, region_filter, tag_key)
    ]

    payload: dict[str, Any] = {
        "mode": mode,
        "query_region": query_region,
        "source_counts": {
            "resource_explorer": len(re_rows),
            "tagging_api": len(tag_rows),
            "merged_unique": len(resources),
        },
        "coverage": coverage,
        "filters_applied": {
            k: v for k, v in {
                "service": service, "resource_type": resource_type,
                "region": region_filter, "tag_key": tag_key,
            }.items() if v
        },
    }
    if warnings:
        payload["warnings"] = warnings

    if warnings or coverage["blind_spots"]:
        payload["completeness"] = (
            "PARTIAL — this is not a complete inventory. See coverage.blind_spots. "
            "When answering the user, state which regions and tag data are covered; "
            "do not present this as the full estate."
        )
    else:
        payload["completeness"] = (
            f"Both sources succeeded across {', '.join(coverage['regions_covered'])}. "
            "No single AWS API returns a complete cn inventory, so this is a merge of "
            "Resource Explorer and the Tagging API; see source_counts for the overlap."
        )

    if mode == "summary":
        payload["summary"] = _summarize(filtered)
        payload["next_steps"] = (
            "Call again with mode='list' plus a service/resource_type/region filter "
            "to enumerate a subset."
        )
    elif mode == "list":
        payload["truncated"] = len(filtered) > limit
        payload["returned"] = min(len(filtered), limit)
        payload["matched"] = len(filtered)
        payload["resources"] = [
            {
                "arn": r["arn"],
                "name": _display_name(r),
                "type": r["type"],
                "region": r["region"],
                "tags": r["tags"],
            }
            for r in filtered[:limit]
        ]
    elif mode == "detail":
        payload["truncated"] = len(filtered) > limit
        payload["resources"] = filtered[:limit]
    else:
        return {"error": f"unknown mode {mode!r}; expected summary, list or detail"}

    return payload
