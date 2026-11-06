#!/usr/bin/env python3
"""Private-runner RDS/S3/OpenSearch data-path checks against Terraform outputs.

Uses boto3 and psycopg[binary] supplied by the approved verification runner.
Every live invocation needs explicit account/environment confirmations. Secret
values stay in process memory; this emits only bounded non-secret receipts.
"""
import argparse
import json
from pathlib import Path
import re
import ssl
import sys
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPSHandler, ProxyHandler, HTTPRedirectHandler


class Failed(Exception):
    pass


def require(condition):
    if not condition:
        raise Failed("Verification gate failed")


def validate(config, account, environment, run_id):
    require(isinstance(config, dict) and config.get("account_id") == account and config.get("environment") == environment)
    require(bool(re.fullmatch(r"[0-9]{12}", account)))
    require(bool(re.fullmatch(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", environment)))
    require(bool(re.fullmatch(r"[0-9a-f]{32}", run_id)))
    require(bool(re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", config["region"])))
    search, pg, storage = (config[k] for k in ("search", "postgres", "storage"))
    url = urlsplit(search["url"])
    require(url.scheme == "https" and url.port in (None, 443) and url.username is None and url.password is None and url.path in ("", "/") and not url.query and not url.fragment)
    require(url.hostname is not None and url.hostname.endswith(f".{config['region']}.es.amazonaws.com"))
    require(search["domain_arn"] == f"arn:aws:es:{config['region']}:{account}:domain/{search['domain_name']}")
    require(bool(re.fullmatch(r"[a-z][a-z0-9-]{2,27}", search["domain_name"])))
    require(search["index_prefix"].endswith(f"-{environment}-"))
    require(bool(re.fullmatch(r"[a-z][a-z0-9-]+-", search["index_prefix"])))
    require(search["domain_name"] == search["index_prefix"] + "search")
    for key in ("master_role_arn", "indexer_role_arn", "reader_role_arn"):
        require(bool(re.fullmatch(f"arn:aws:iam::{account}:role/.+", search[key])))
    require(search["indexer_role_arn"] != search["reader_role_arn"])
    require(search["master_role_arn"] not in (search["indexer_role_arn"], search["reader_role_arn"]))
    require(storage["prefix"] == f"proofs/{environment}/")
    require(storage["bucket"] == f"{search['index_prefix']}{account}-{config['region']}-sessions")
    require(bool(re.fullmatch(f"arn:aws:iam::{account}:role/.+", storage["role_arn"])))
    require(storage["role_arn"] != search["master_role_arn"])
    require(pg["secret_arn"].startswith(f"arn:aws:secretsmanager:{config['region']}:{account}:secret:"))
    require(pg["resource_arn"].startswith(f"arn:aws:rds:{config['region']}:{account}:"))
    require(pg["host"].endswith(f".{config['region']}.rds.amazonaws.com"))
    pipeline = config.get("pipeline")
    if pipeline is not None:
        require(pipeline["function_arn"].startswith(f"arn:aws:lambda:{config['region']}:{account}:function:"))
        require(bool(re.fullmatch(f"arn:aws:iam::{account}:role/.+", search["lambda_role_arn"])))
        require(search["lambda_role_arn"] not in (search["master_role_arn"], search["reader_role_arn"]))
    return config


def role_matches(caller, expected):
    if caller == expected:
        return True
    match = re.fullmatch(r"arn:aws:sts::([0-9]{12}):assumed-role/([^/]+)/[^/]+", caller)
    role = re.fullmatch(r"arn:aws:iam::([0-9]{12}):role/(.+)", expected)
    return bool(match and role and match[1] == role[1] and match[2] == role[2].split("/")[-1])


def bulk_is_refused(status, body):
    if status == 403:
        return True
    if status != 200 or not isinstance(body, dict) or body.get("errors") is not True:
        return False
    items = body.get("items")
    return isinstance(items, list) and len(items) == 1 and isinstance(items[0], dict) and isinstance(items[0].get("index"), dict) and items[0]["index"].get("status") == 403


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        # Never forward a signed request or its session token to another URL.
        return None


def security_ack(status, body):
    require(status in (200, 201) and isinstance(body, dict) and body.get("status") in ("CREATED", "OK"))


def index_ack(status, body):
    require(status == 200 and isinstance(body, dict) and body.get("acknowledged") is True)


def document_ack(status, body, index, identifier):
    require(status in (200, 201) and isinstance(body, dict) and body.get("result") in ("created", "updated") and body.get("_index") == index and body.get("_id") == identifier and body.get("_shards", {}).get("failed") == 0)


class Search:
    def __init__(self, session, url, region):
        self.session, self.url, self.region = session, url.rstrip("/"), region
        self.http = build_opener(ProxyHandler({}), NoRedirect(), HTTPSHandler(context=ssl.create_default_context()))

    def call(self, method, path, body=None, ndjson=False):
        from botocore.auth import SigV4Auth
        from botocore.awsrequest import AWSRequest
        data = body.encode() if ndjson else (json.dumps(body).encode() if body is not None else None)
        headers = {"Content-Type": "application/x-ndjson" if ndjson else "application/json"}
        aws = AWSRequest(method=method, url=self.url + path, data=data, headers=headers)
        credentials = self.session.get_credentials()
        require(credentials is not None)
        SigV4Auth(credentials.get_frozen_credentials(), "es", self.region).add_auth(aws)
        request = Request(aws.url, data=data, headers=dict(aws.headers.items()), method=method)
        try:
            with self.http.open(request, timeout=30) as response:
                status, raw = response.status, response.read(2_000_001)
        except HTTPError as error:
            status, raw = error.code, error.read(2_000_001)
        require(len(raw) <= 2_000_000 and not 300 <= status < 400)
        try:
            result = json.loads(raw) if raw else {}
        except (ValueError, UnicodeError) as exc:
            raise Failed("Non-JSON service response") from exc
        return status, result


def postgres(session, config, ca_path):
    require(ca_path is not None and ca_path.is_file())
    import psycopg
    pg = config["postgres"]
    arn = pg["resource_arn"]
    kind, identifier = arn.split(":", 6)[5:]
    rds = session.client("rds")
    if kind == "db":
        database = rds.describe_db_instances(DBInstanceIdentifier=identifier)["DBInstances"][0]
        require(database["DBInstanceArn"] == arn and database["PubliclyAccessible"] is False)
        host = database["Endpoint"]["Address"]
    else:
        require(kind == "cluster")
        database = rds.describe_db_clusters(DBClusterIdentifier=identifier)["DBClusters"][0]
        require(database["DBClusterArn"] == arn)
        for member in database["DBClusterMembers"]:
            instance = rds.describe_db_instances(DBInstanceIdentifier=member["DBInstanceIdentifier"])["DBInstances"][0]
            require(instance["PubliclyAccessible"] is False)
        host = database["Endpoint"]
    require(host == pg["host"] and database["MasterUserSecret"]["SecretArn"] == pg["secret_arn"])
    require(database["StorageEncrypted"] is True and database["BackupRetentionPeriod"] == pg["backup_retention_days"] and database["DeletionProtection"] == pg["deletion_protection"])
    secret = json.loads(session.client("secretsmanager").get_secret_value(SecretId=pg["secret_arn"])["SecretString"])
    with psycopg.connect(host=host, port=pg["port"], dbname=pg["database"], user=secret["username"], password=secret["password"], sslmode="verify-full", sslrootcert=str(ca_path.resolve()), connect_timeout=15) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_database(), current_setting('server_version_num')::int, ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()")
            row = cursor.fetchone()
            require(row is not None and row[0] == pg["database"] and 170000 <= row[1] < 180000 and row[2] is True)
            cursor.execute("CREATE TEMP TABLE agent_relay_connection_proof (marker text) ON COMMIT DROP")
            cursor.execute("INSERT INTO agent_relay_connection_proof VALUES (%s)", ("authenticated-private-tls",))
            cursor.execute("SELECT marker FROM agent_relay_connection_proof")
            require(cursor.fetchone() == ("authenticated-private-tls",))


def configuration(session, config):
    client = session.client("s3")
    bucket = config["storage"]["bucket"]
    public = client.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
    require(all(public.get(k) is True for k in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")))
    require(client.get_bucket_versioning(Bucket=bucket).get("Status") == "Enabled")
    rules = client.get_bucket_encryption(Bucket=bucket)["ServerSideEncryptionConfiguration"]["Rules"]
    require(len(rules) == 1 and rules[0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "aws:kms" and rules[0].get("BucketKeyEnabled") is True)
    policy = json.loads(client.get_bucket_policy(Bucket=bucket)["Policy"])
    require(any(s.get("Effect") == "Deny" and s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") in (False, "false") for s in policy.get("Statement", [])))
    search = config["search"]
    domain = session.client("opensearch").describe_domain(DomainName=search["domain_name"])["DomainStatus"]
    require(domain["ARN"] == search["domain_arn"] and domain["Endpoints"]["vpc"] == urlsplit(search["url"]).hostname and domain["VPCOptions"].get("VPCId"))
    require(domain["DomainEndpointOptions"]["EnforceHTTPS"] and domain["EncryptionAtRestOptions"]["Enabled"] and domain["NodeToNodeEncryptionOptions"]["Enabled"] and domain["AdvancedSecurityOptions"]["Enabled"])


def lambda_smoke(session, config, code_sha):
    pipeline = config.get("pipeline")
    require(isinstance(pipeline, dict))
    client = session.client("lambda")
    function = client.get_function(FunctionName=pipeline["function_arn"])
    deployed = function["Configuration"]
    require(deployed["FunctionArn"] == pipeline["function_arn"] and deployed["State"] == "Active" and deployed["LastUpdateStatus"] == "Successful")
    require(deployed["Architectures"] == ["arm64"] and deployed["VpcConfig"]["SubnetIds"] and deployed["VpcConfig"]["SecurityGroupIds"])
    if pipeline.get("image_uri"):
        require(function["Code"]["ResolvedImageUri"] == pipeline["image_uri"])
    else:
        require(isinstance(code_sha, str) and code_sha and deployed["CodeSha256"] == code_sha and deployed["Runtime"] == "nodejs24.x")
    # Reconcile may run up to the function deadline. Do not let an SDK timeout
    # retry this explicit invocation and accidentally start a second run.
    from botocore.config import Config
    client = session.client("lambda", config=Config(connect_timeout=15, read_timeout=deployed["Timeout"] + 30, retries={"total_max_attempts": 1}))
    response = client.invoke(FunctionName=pipeline["function_arn"], InvocationType="RequestResponse", Payload=b'{"reconcile":true}')
    require(response["StatusCode"] == 200 and not response.get("FunctionError"))
    body = json.loads(response["Payload"].read())
    require(isinstance(body, dict) and body.get("ok") is True)


def storage(session, config, run_id):
    value = config["storage"]
    key = value["prefix"] + run_id + "/marker.json"
    client = session.client("s3")
    body = json.dumps({"marker": run_id}).encode()
    # Only the synthetic current key is deleted. Version history remains under
    # normal retention; an approved administrator cleans versions at retirement.
    try:
        client.put_object(Bucket=value["bucket"], Key=key, Body=body)
        result = client.get_object(Bucket=value["bucket"], Key=key)
        require(result["Body"].read() == body)
        require(any(x["Key"] == key for x in client.list_objects_v2(Bucket=value["bucket"], Prefix=key).get("Contents", [])))
    finally:
        client.delete_object(Bucket=value["bucket"], Key=key)


def search_phase(session, config, phase, run_id):
    search = config["search"]
    client = Search(session, search["url"], config["region"])
    index = search["index_prefix"] + "proof-" + run_id
    denied = "denied-proof-" + run_id
    role = f"agent_relay_proof_{config['environment']}_{run_id}"
    if phase == "search-bootstrap":
        domain = session.client("opensearch").describe_domain(DomainName=search["domain_name"])["DomainStatus"]
        require(domain["ARN"] == search["domain_arn"] and domain["Endpoints"]["vpc"] == urlsplit(search["url"]).hostname)
        require(domain["VPCOptions"].get("VPCId") and domain["AdvancedSecurityOptions"]["Enabled"])
        writer_roles = [search["indexer_role_arn"]] + ([search["lambda_role_arn"]] if search.get("lambda_role_arn") else [])
        for suffix, actions, principals in [("writer", ["crud", "create_index"], writer_roles), ("reader", ["read"], [search["reader_role_arn"]])]:
            security_ack(*client.call("PUT", f"/_plugins/_security/api/roles/{role}_{suffix}", {"cluster_permissions": ["cluster_composite_ops_ro"], "index_permissions": [{"index_patterns": [index], "allowed_actions": actions}], "tenant_permissions": []}))
            security_ack(*client.call("PUT", f"/_plugins/_security/api/rolesmapping/{role}_{suffix}", {"backend_roles": principals, "hosts": [], "users": []}))
        for name in (index, denied):
            index_ack(*client.call("PUT", f"/{name}", {"mappings": {"properties": {"marker": {"type": "keyword"}}}}))
        document_ack(*client.call("PUT", f"/{denied}/_doc/private?refresh=true", {"marker": run_id}), denied, "private")
    elif phase == "search-write":
        document_ack(*client.call("PUT", f"/{index}/_doc/accepted?refresh=true", {"marker": run_id}), index, "accepted")
    elif phase == "search-read":
        status, body = client.call("POST", f"/{index}/_search", {"query": {"term": {"marker": run_id}}})
        require(status == 200 and body.get("timed_out") is False and body.get("_shards", {}).get("failed") == 0)
        hits = body.get("hits", {}).get("hits")
        require(isinstance(hits, list) and len(hits) == 1 and hits[0].get("_id") == "accepted" and hits[0].get("_source", {}).get("marker") == run_id)
        status, _ = client.call("PUT", f"/{index}/_doc/refused", {"marker": run_id})
        require(status == 403)
        body = json.dumps({"index": {"_index": index, "_id": "refused-bulk"}}) + "\n" + json.dumps({"marker": run_id}) + "\n"
        status, result = client.call("POST", "/_bulk", body, ndjson=True)
        require(bulk_is_refused(status, result))
        status, _ = client.call("GET", f"/{denied}/_search")
        require(status == 403)
    elif phase == "search-cleanup":
        # Refusal must have had zero write effects, not merely an error response.
        for doc in ("refused", "refused-bulk"):
            status, body = client.call("GET", f"/{index}/_doc/{doc}")
            require(status == 404 and body.get("found") is False and body.get("_index") == index and body.get("_id") == doc)
        for name in (index, denied):
            index_ack(*client.call("DELETE", f"/{name}"))
        for suffix in ("writer", "reader"):
            for resource in ("rolesmapping", "roles"):
                security_ack(*client.call("DELETE", f"/_plugins/_security/api/{resource}/{role}_{suffix}"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["configuration", "postgres", "storage", "search-bootstrap", "search-write", "search-read", "search-cleanup", "lambda-smoke"])
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--run-id", required=True, help="One shared random UUID in 32-character lowercase hex form")
    parser.add_argument("--confirm-account", required=True)
    parser.add_argument("--confirm-environment", required=True)
    parser.add_argument("--confirm-live", action="store_true", required=True)
    parser.add_argument("--rds-ca", type=Path)
    parser.add_argument("--lambda-code-sha256", help="Reviewed Lambda ZIP CodeSha256 in base64; required for ZIP smoke")
    args = parser.parse_args(argv)
    config = validate(json.loads(args.config.read_text()), args.confirm_account, args.confirm_environment, args.run_id)
    import boto3
    session = boto3.Session(region_name=config["region"])
    caller = session.client("sts").get_caller_identity()
    require(caller["Account"] == config["account_id"])
    role_keys = {"storage": ("storage", "role_arn"), "search-bootstrap": ("search", "master_role_arn"), "search-write": ("search", "indexer_role_arn"), "search-read": ("search", "reader_role_arn"), "search-cleanup": ("search", "master_role_arn")}
    if args.phase in role_keys:
        section, key = role_keys[args.phase]
        require(role_matches(caller["Arn"], config[section][key]))
    if args.phase == "configuration":
        configuration(session, config)
    elif args.phase == "lambda-smoke":
        lambda_smoke(session, config, args.lambda_code_sha256)
    elif args.phase == "postgres":
        postgres(session, config, args.rds_ca)
    elif args.phase == "storage":
        storage(session, config, args.run_id)
    else:
        search_phase(session, config, args.phase, args.run_id)
    print(json.dumps({"result": "PASS", "phase": args.phase, "environment": config["environment"], "run_id": args.run_id}))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"result": "FAIL", "error_class": type(exc).__name__}), file=sys.stderr)
        sys.exit(1)
