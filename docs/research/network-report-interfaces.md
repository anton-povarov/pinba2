# Network interfaces for Pinba reports

Research date: 2026-08-28.

## Scope

Pinba's aggregation engine remains authoritative. This note compares mature SQL
and non-SQL interfaces that can expose both report definition and report-row
selection over a TCP network. It excludes external aggregation engines,
embedded analytical databases, experimental network protocols, and interfaces
whose transport contract is still a draft.

Sources are primary specifications and first-party documentation.

## Decision

The strongest overall interface for manual relational exploration is a
**Pinba-owned SQL service over PostgreSQL wire protocol 3.0 and TCP/TLS**. It
preserves the familiar table model and connects through `psql`, libpq, JDBC,
language drivers, and database tools without requiring a PostgreSQL server.

The strongest non-SQL alternative is **OData 4.01 over HTTPS**, implementing a
documented read/query profile and the updatable operations needed for report
definitions.

The decision depends on which compatibility target matters most:

| Priority | Recommended interface |
|---|---|
| Existing database clients and interactive tabular exploration | PostgreSQL wire + Pinba SQL |
| Standardized non-SQL filtering and BI/data-feed clients | OData 4.01 |
| Universal HTTP reach with the smallest public contract | REST/JSON + OpenAPI, accepting Pinba-specific query semantics |

Do not expose both SQL and OData initially. They would create two public query
languages, two metadata models, and two compatibility matrices over the same
reports.

## SQL option 1: PostgreSQL wire with Pinba SQL

### Contract

```text
transport:           PostgreSQL frontend/backend protocol 3.0 over TCP + TLS
definition language: Pinba CREATE/REPLACE/DROP REPORT statements
query language:      documented read-oriented SQL subset
schema discovery:    information_schema + a deliberately small pg_catalog
aggregation owner:   Pinba
```

PostgreSQL's frontend/backend protocol is message-based and explicitly supports
TCP/IP. Protocol 3.0 has been supported since PostgreSQL 7.4, and current libpq
remains backward compatible with it
([protocol overview](https://www.postgresql.org/docs/current/protocol.html),
[protocol flow](https://www.postgresql.org/docs/current/protocol-flow.html)).

PostgreSQL wire is only the transport contract. It does not supply SQL parsing,
query execution, session behavior, type semantics, or catalogs. Those remain
Pinba responsibilities.

### Define reports remotely

Use domain-specific DDL rather than pretending Pinba supports arbitrary
incremental materialized views:

```sql
CREATE REPORT requests_by_script
WITH (
    source = 'request',
    window = '60s',
    tick = '1s',
    keys = ARRAY['~script'],
    percentiles = ARRAY[95, 99, 99.9]
);
```

```sql
CREATE OR REPLACE REPORT db_by_server
WITH (
    source = 'timer',
    window = '60s',
    tick = '1s',
    keys = ARRAY['+application', '@server'],
    filters = MAP['@group', 'db'],
    percentiles = ARRAY[95, 99]
);
```

Also support:

```sql
SHOW REPORTS;
SHOW CREATE REPORT requests_by_script;
DROP REPORT requests_by_script;
```

`CREATE REPORT` is intentionally Pinba syntax. Calling the object a standard
materialized view would imply general incremental-query semantics, arbitrary
source relations, and refresh behavior that Pinba does not implement.

A versioned report file can remain a client-side batch format:

```console
pinba reports apply \
  --endpoint 'postgres://admin@pinba.example:3003/pinba?sslmode=require' \
  reports.toml
```

The client submits one atomic desired-state replacement over TCP; the server
does not read the client's filesystem.

### Select report rows

```sql
SELECT script, req_per_sec, p99
FROM requests_by_script
WHERE req_count > 100
ORDER BY p99 DESC
LIMIT 20;
```

The initial SQL surface should be explicit:

- projection, aliases, literals, and basic scalar expressions;
- `WHERE`, `ORDER BY`, `LIMIT`, and `OFFSET`;
- optional aggregation over already-published report rows;
- read-only report and status relations;
- one immutable report snapshot per statement;
- structured errors for unsupported syntax.

Joins, subqueries, window functions, mutation of report rows, arbitrary DDL,
stored procedures, and PostgreSQL transaction semantics should not be implied
unless deliberately implemented.

### Client compatibility obligations

Speaking PostgreSQL wire does not automatically make Pinba PostgreSQL-compatible.
Real clients use:

- startup parameters and session `SET`/`SHOW` commands;
- simple and extended query flows (`Parse`, `Bind`, `Describe`, `Execute`);
- PostgreSQL type OIDs and text/binary encodings;
- cancellation and TLS negotiation;
- `information_schema` and `pg_catalog` introspection queries.

PostgreSQL documents these protocol flows and its system catalogs separately
([message flow](https://www.postgresql.org/docs/current/protocol-flow.html),
[system catalogs](https://www.postgresql.org/docs/current/catalogs.html)).

Pinba should publish a tested compatibility profile rather than claim generic
PostgreSQL compatibility. A reasonable first profile is:

- `psql` interactive queries;
- libpq;
- pgx;
- PostgreSQL JDBC;
- selected GUI clients using explicitly supported metadata views.

This option has the best client ecosystem, but also the greatest compatibility
surface that Pinba itself must maintain.

## SQL option 2: SQL over HTTPS

SQL can also be exposed through an ordinary HTTP endpoint:

```http
POST /v1/query HTTP/1.1
Host: pinba.example
Authorization: Bearer ...
Content-Type: application/json

{
  "query": "SELECT script, req_per_sec, p99 FROM requests_by_script WHERE req_count > $1 ORDER BY p99 DESC LIMIT $2",
  "parameters": [100, 20]
}
```

Results can use a typed JSON envelope with bounded pages or NDJSON streaming.
Report definitions can be submitted through the same endpoint using Pinba DDL,
or through fixed REST resources.

HTTP is standardized and universally deployable, but **SQL over HTTP is not one
interoperable database protocol**. `curl` and generic HTTP libraries work;
`psql`, PostgreSQL JDBC, ODBC tools, and database explorers do not. OpenAPI can
describe the endpoint, but it cannot give generic clients SQL-session or catalog
behavior
([HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110),
[OpenAPI 3.0.4](https://spec.openapis.org/oas/v3.0.4.html)).

Choose this only when retaining SQL syntax matters but database-client
compatibility does not.

## Non-SQL recommendation: OData 4.01

OData is an OASIS standard approved in 2020 and is also an ISO/IEC standard. It
defines a REST data model, typed metadata, JSON representations, standard query
options, pagination, actions, batch requests, and atomicity groups
([OData 4.01 standard](https://www.oasis-open.org/standard/odata-v4-01-os/),
[protocol](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html)).
It therefore avoids inventing a Pinba-specific filter and projection language
while retaining ordinary HTTP/TLS deployment and clients.

The public contract would be:

```text
transport:           HTTPS over TCP
representation:      OData 4.01 JSON
schema discovery:    GET /odata/$metadata
report control:      ReportDefinitions entities + ApplyReportSet action
row selection:       report entity sets + OData query options
aggregation owner:   Pinba
```

Pinba should target the **OData 4.01 Intermediate conformance level**, plus
`$orderby`, server-driven paging, metadata, ETags, and the updatable operations
used by report definitions. The specification explicitly defines conformance
levels so the supported surface can be precise instead of implying all OData
features ([OData conformance](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html#_Toc31358955)).

### Recommended OData interface

#### Define or replace one report

Treat report definitions as typed OData entities:

```http
PUT /odata/ReportDefinitions('requests_by_script') HTTP/1.1
Host: pinba.example
Authorization: Bearer ...
Content-Type: application/json
OData-Version: 4.01
If-Match: "catalog-41"

{
  "name": "requests_by_script",
  "source": "request",
  "window": "PT60S",
  "tick": "PT1S",
  "keys": [
    { "source": "request_field", "name": "script", "column": "script" }
  ],
  "filters": [],
  "histogram": {
    "minimum": "PT0S",
    "maximum": "PT2S",
    "buckets": 20000,
    "percentiles": [95, 99, 99.9]
  }
}
```

`If-Match` makes replacement conditional on the catalog revision observed by
the client. HTTP defines conditional request semantics, while OData JSON defines
ETag control information
([HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110),
[OData JSON format](https://docs.oasis-open.org/odata/odata-json-format/v4.01/os/odata-json-format-v4.01-os.html)).

Deletion is ordinary OData resource deletion:

```http
DELETE /odata/ReportDefinitions('requests_by_script')
If-Match: "catalog-42"
```

#### Atomically replace the complete report set

Expose a service-defined OData action:

```http
POST /odata/Pinba.ApplyReportSet
Content-Type: application/json
If-Match: "catalog-42"

{
  "revision": "deploy-2026-08-28.3",
  "reports": [ ... ]
}
```

OData actions are typed operations with side effects. OData batch atomicity
groups are also standardized, but one `ApplyReportSet` action better expresses
Pinba's desired-state rule: validate the complete candidate before publishing
any changes
([OData actions](https://docs.oasis-open.org/odata/odata/v4.01/os/part3-csdl/odata-v4.01-os-part3-csdl.html#_Toc453752619),
[batch requests](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html#_Batch_Requests)).

A local file remains useful only as a client artifact:

```console
pinba reports apply --endpoint https://pinba.example/odata reports.toml
```

The CLI translates the file to `ApplyReportSet`; the server never depends on
the client's filesystem.

#### Discover reports and schemas

```http
GET /odata/
GET /odata/$metadata
GET /odata/ReportDefinitions?$select=name,source,window,tick
```

OData services publish a service document listing entity sets and a `$metadata`
document describing types, properties, sets, functions, and actions. Generic
clients use this model for discovery
([OData service model](https://docs.oasis-open.org/odata/odata/v4.01/csprd01/part1-protocol/odata-v4.01-csprd01-part1-protocol.html#_Service_Model),
[CSDL metadata](https://docs.oasis-open.org/odata/odata-csdl-json/v4.01/cs01/odata-csdl-json-v4.01-cs01.html)).

Each active report is published as a read-only entity set with a generated
type. Its aggregation keys form the OData entity key. A packet-level report,
which has no aggregation key, is published as an OData singleton.

When definitions change, `$metadata` changes and receives a new metadata ETag.
Long-lived clients must refresh metadata when that ETag changes.

#### Select rows

```http
GET /odata/requests_by_script?%24select=script,req_per_sec,p99&%24filter=req_count%20gt%20100&%24orderby=p99%20desc&%24top=20
Accept: application/json
OData-MaxVersion: 4.01
```

Readable form:

```text
/odata/requests_by_script
  ?$select=script,req_per_sec,p99
  &$filter=req_count gt 100
  &$orderby=p99 desc
  &$top=20
```

The OData URL conventions standardize `$select`, `$filter`, `$orderby`, `$top`,
`$skip`, `$count`, operators, and functions. These are the non-SQL equivalents
of the report exploration operations Pinba needs
([OData URL conventions](https://docs.oasis-open.org/odata/odata/v4.01/os/part2-url-conventions/odata-v4.01-os-part2-url-conventions.html)).

Response:

```json
{
  "@context": "$metadata#requests_by_script(script,req_per_sec,p99)",
  "value": [
    { "script": "/checkout", "req_per_sec": 48.2, "p99": 0.231 },
    { "script": "/search", "req_per_sec": 31.7, "p99": 0.190 }
  ]
}
```

For large reports, the server returns a bounded page and an opaque `@nextLink`.
OData requires interoperable clients to follow next links. Pinba's continuation
token must identify and retain the same immutable snapshot, projection, order,
and filter until it expires; otherwise page boundaries would drift as the live
report changes
([OData JSON `nextLink`](https://docs.oasis-open.org/odata/odata-json-format/v4.01/os/odata-json-format-v4.01-os.html#sec_ControlInformationnextLink),
[interoperable clients](https://docs.oasis-open.org/odata/odata/v4.01/odata-v4.01-part1-protocol.html#sec_InteroperableODataClients)).

## Why OData is the strongest fit

### It standardizes the missing query semantics

Plain HTTP and JSON standardize transport and representation, but not how a
client asks for projection, predicates, ordering, or pagination. OData supplies
those semantics without making Pinba implement or claim a general-purpose
language.

### Dynamic report schemas are discoverable

Each report kind has generated columns, and user-defined keys and percentiles
change the schema. OData CSDL describes these types at runtime. The entity model
also has open types if Pinba ever needs a generic fallback, though generated
closed types are preferable because clients retain numeric and nullability
information.

### The client ecosystem is established

The OData project lists client/server libraries for .NET, Java, JavaScript,
C++, and other platforms
([OData libraries](https://www.odata.org/libraries/)). Microsoft ships a
generally available OData Feed connector used by Excel, Power BI, Fabric,
Power Apps, and Analysis Services
([Power Query OData connector](https://learn.microsoft.com/en-us/power-query/connectors/odata-feed)).
Generic HTTP clients such as browsers and `curl` can still use the endpoint
without an OData SDK.

### It has explicit compatibility profiles

OData 4.01 services are also required to be compatible with 4.0. Pinba can
advertise supported capabilities in metadata and return `501 Not Implemented`
for syntactically valid but unsupported operations as required by the
conformance rules. This is safer than approximating unsupported behavior.

## Other mature non-SQL options

### REST/JSON with OpenAPI 3.0

This is the fallback if OData implementation complexity is unacceptable.

```http
POST /v1/reports/requests_by_script/rows:query
Content-Type: application/json

{
  "select": ["script", "req_per_sec", "p99"],
  "where": [{"column":"req_count", "op":"gt", "value":100}],
  "order_by": [{"column":"p99", "direction":"desc"}],
  "limit": 20
}
```

HTTP is an IETF standard and OpenAPI 3.0 is a language-neutral description for
HTTP APIs with broad documentation, client-generation, routing, and testing
tool support
([RFC 9110](https://www.rfc-editor.org/rfc/rfc9110),
[OpenAPI 3.0.4](https://spec.openapis.org/oas/v3.0.4.html)).

Advantages:

- smallest conceptual and implementation surface;
- excellent proxy, TLS, authentication, observability, and browser support;
- fixed control schema is easy to generate clients for;
- JSON requests avoid URL-length limits for complex filters.

Disadvantages:

- the query object, operators, typing rules, pagination, and errors are all
  Pinba-specific;
- generic REST clients understand HTTP but not report selection semantics;
- OpenAPI describes the custom contract but does not make it interoperable with
  unrelated data exploration tools;
- dynamically generated per-report row schemas are awkward in one static
  OpenAPI document.

Choose this only if compatibility means “callable from every language,” rather
than “understood by existing data clients.”

### gRPC with Protocol Buffers

A stable typed RPC could expose:

```protobuf
service PinbaReports {
  rpc ApplyReportSet(ApplyReportSetRequest) returns (ApplyReportSetResponse);
  rpc DescribeReport(DescribeReportRequest) returns (ReportSchema);
  rpc Select(SelectRequest) returns (stream RowBatch);
}
```

gRPC uses Protocol Buffers as its normal interface definition and wire format,
supports generated clients across many languages, and supports server streaming.
Protocol Buffers documents rules for evolving messages without breaking binary
wire compatibility
([gRPC introduction](https://grpc.io/docs/what-is-grpc/introduction/),
[supported languages](https://grpc.io/docs/languages/),
[Protobuf compatibility](https://protobuf.dev/programming-guides/proto3/#updating)).

Reflection allows tools such as `grpcurl` and Postman to discover services
([gRPC reflection](https://grpc.io/docs/guides/reflection/)).

It is nevertheless a weaker public exploration interface:

- clients normally need generated stubs;
- dynamic report columns require a generic `Value`/column schema or runtime
  descriptors, losing much of Protobuf's static typing advantage;
- filtering and ordering still require a custom Pinba expression AST;
- browsers require gRPC-Web infrastructure;
- manual use is less convenient than a URL and JSON response.

gRPC is suitable as a machine-to-machine companion interface, not the primary
operator-facing contract.

### Prometheus-compatible HTTP query interface

Pinba could project selected report measures as labeled metrics and implement
the stable Prometheus `/api/v1/query` endpoint and PromQL evaluation. Prometheus
documents its query language, data model, recording rules, and v1 HTTP API as
stable within a major version
([stability policy](https://prometheus.io/docs/prometheus/latest/stability/),
[HTTP query API](https://prometheus.io/docs/prometheus/latest/querying/api/)).

This gives strong compatibility with monitoring clients, but it is not a
lossless primary interface for Pinba reports:

- one report row with many measures becomes many time series;
- string dimensions become labels and numeric columns become samples;
- arbitrary projection and row pagination do not map naturally;
- high-cardinality report keys become high-cardinality label sets;
- range queries require retained historical samples, while Pinba exposes a
  current bounded snapshot;
- PromQL does not remotely define Pinba's report lifecycle, so report control
  remains a separate custom API.

It is valuable as an optional compatibility projection for dashboards and
alerts, but not as the canonical definition-and-selection interface.

### JSON-RPC 2.0

JSON-RPC 2.0 has been unchanged since 2013 and can run over HTTP or sockets. It
defines requests, responses, errors, notifications, and batches
([JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification)).

Methods such as `reports.apply`, `reports.describe`, and `reports.select` would
be straightforward. However, JSON-RPC deliberately does not define service
schema discovery, pagination, typed resources, filtering, ordering, or report
rows. Almost all interoperability would still come from a custom Pinba method
contract. Plain REST plus OpenAPI offers better discoverability and tooling for
the same JSON-level simplicity.

## Ranking

| Rank | Interface | Client compatibility | Standard selection semantics | Dynamic schema discovery | Manual exploration | Verdict |
|---:|---|---|---|---|---|---|
| 1 | PostgreSQL wire + Pinba SQL | Strongest database-client ecosystem | Yes, documented SQL subset | `information_schema` and supported `pg_catalog` | Excellent | Overall recommendation |
| 2 | OData 4.01/HTTPS | Strong, especially data and BI clients | Yes | Yes, CSDL `$metadata` | Good | Recommended non-SQL option |
| 3 | SQL over HTTPS | Universal HTTP clients; not database clients | Yes, documented SQL subset | Custom/OpenAPI | Good with a Pinba console | SQL without client compatibility |
| 4 | REST/JSON + OpenAPI 3.0 | Universal HTTP clients | No; Pinba-specific | Partial | Good | Simpler non-SQL fallback |
| 5 | gRPC + Protobuf | Strong generated-client ecosystem | No; Pinba-specific | Reflection plus custom schema | Fair | Machine companion only |
| 6 | Prometheus HTTP + PromQL | Excellent monitoring ecosystem | Yes, for time series | Metric metadata, not row schemas | Good for metrics | Optional projection only |
| 7 | JSON-RPC 2.0 | Broad generic libraries | No | No standard mechanism | Fair | No advantage over REST |

## Compatibility and security requirements

Whichever network interface is chosen:

- TLS is mandatory for non-loopback TCP listeners.
- Authentication and authorization must distinguish report readers from report
  administrators.
- Report replacement requires optimistic concurrency (`ETag`/`If-Match`) and
  an audit record.
- Query timeout, maximum page size, maximum result bytes, and connection limits
  are part of the public contract.
- Unsupported query features return explicit errors; they are never silently
  approximated.
- Pagination pins an immutable snapshot and uses opaque, expiring continuation
  tokens.
- Schema metadata states report generation, catalog revision, window bounds,
  and snapshot timestamp.
- Compatibility is verified against named client versions and an advertised
  protocol/query profile.

## Bottom line

For the broadest existing client ecosystem and the best manual exploration,
expose Pinba-owned report DDL and a documented SQL subset over PostgreSQL wire
protocol 3.0/TCP. This keeps Pinba's aggregation engine authoritative and uses
PostgreSQL only as a network compatibility contract.

That choice carries a serious obligation: implement and test the protocol,
types, session behavior, and metadata queries actually used by supported
clients. Do not equate successful row framing with PostgreSQL compatibility.

If a non-SQL public contract is preferred, use a genuine,
capability-advertised OData 4.01 service over HTTPS. OData is the only non-SQL
option evaluated that standardizes both typed schema discovery and the row
selection operations Pinba needs. REST/OpenAPI, gRPC, and JSON-RPC standardize
transport or invocation but leave selection semantics custom. Prometheus
standardizes selection for time series, not relational report rows.
