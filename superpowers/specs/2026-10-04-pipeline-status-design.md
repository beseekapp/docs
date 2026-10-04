# Pipeline Status on File Details — Design

Date: 2026-10-04 · Status: approved design, pending implementation plan

## Problem

After upload, workspace files go through an asynchronous pipeline:
transformer (conversion) → indexer (text + embeddings) → extractor (entities/graph).
None of it is visible to users. The Processing tab on File Details only checks
whether artifact IDs exist on `file_metadata`, so a failed or still-running stage
looks identical to "Not available".

Each stage already publishes success/failure events (`file.transformed`,
`file.transformation_failed`, `file.indexed`, `file.indexing_failed`,
`file.indexing_skipped`, `file.extracted`, `file.extraction_failed`), but nothing
consumes the failure/skipped events, and no stage emits a "started" signal.

Example: `pg10907.txt` (`6ac21fb802adbf2cc0ee`) failed indexing on a Bifrost 429;
the user saw only "Text Extraction: Not available".

## Goal

Show, per file, one row per pipeline stage with status
**Waiting / Running / Done / Skipped / Failed**, timestamps, a user-readable
error, and a Retry action on failure.

Non-goals: progress within a stage (e.g. "4,200 / 19,136 embedded"), realtime
push, pipeline status in the file list (enabled by this design, but not in scope).

## Approach

Each stage service writes its own status onto the `file_metadata` document, using
the Appwrite write path it already uses for artifact IDs. The webapp reads these
fields and polls while the pipeline is active.

Rejected:
- **Status-collector subscriber**: requires new "started" events and a new consumer for
  the same outcome.
- **Live Dapr workflow queries from the webapp**: three service calls per page view,
  and workflow history is purged, so finished files lose their status.

## 1. Data model

New attributes on the `file_metadata` collection, defined in
`platform40-appwrite/provisioning/domain/collections/knowledge.py`:

| Stage | Owner | Attributes |
|---|---|---|
| Conversion | transformer | `conversion_status`, `conversion_started_at`, `conversion_finished_at`, `conversion_error` |
| Indexing | indexer | `indexing_status`, `indexing_started_at`, `indexing_finished_at`, `indexing_error` |
| Extraction | extractor | `extraction_status`, `extraction_started_at`, `extraction_finished_at`, `extraction_error` |

- `*_status`: enum `running | done | failed | skipped`, optional. **Null = waiting.**
- `*_started_at`, `*_finished_at`: ISO-8601 datetime strings (existing convention), optional.
- `*_error`: string, max 500 chars, optional. A user-readable message for `failed`,
  or the reason for `skipped`.
- No backfill. Existing documents have null statuses.
- **Ownership rule:** a service writes only its own stage's four attributes.

## 2. Service write points

The same pattern applies in transformer, indexer and extractor, implemented in each
service's existing Appwrite database adapter.

| Moment | Location | Write |
|---|---|---|
| Stage starts | Start of the main activity (`transform_document_activity`, `index_document_activity`, the extractor's main activity) | `status=running`, `started_at=now`, `finished_at=null`, `error=null` |
| Stage succeeds | End of the main activity, after artifacts are persisted | `status=done`, `finished_at=now` |
| Not applicable | Transformer passthrough (e.g. `.txt`); indexer `file.indexing_skipped` path | `status=skipped`, `finished_at=now`, `error=<reason>` |
| Fails after retries | Existing `publish_failure_activity` in each service | `status=failed`, `finished_at=now`, `error=<friendly message>` |

Rules:
- Writes happen in **activities only**, never in workflow functions, which are
  replayed by Dapr.
- During activity retries the status stays `running`.
- Status writes are **best-effort**. Failures are logged as warnings and never fail
  the pipeline, matching the existing `update_text_artifact` handling.
- Each service maps known exceptions to friendly messages. Indexer examples:
  `EmbeddingError` with HTTP 429 → "AI provider rate limit reached — retry later";
  `DocumentParseError` → "File could not be read". Anything else → "Processing failed".
  Full details stay in logs and traces.
- Stages are triggered sequentially by success events, so status writes cannot
  interleave across stages on the happy path.

## 3. Webapp

### Pipeline block

Added at the top of the Processing tab
(`platform40-webapp/src/components/files/application/file_details_content.py`),
above the existing Text / PDF / Thumbnail artifact rows, which stay unchanged.

```
Pipeline                                        ⟳ refreshing…
 ① Conversion   – Skipped   Not needed for plain text
 ② Indexing     ✕ Failed    AI provider rate limit reached — retry later   [Retry]
                            started 09:43 · failed after 2m 18s
 ③ Extraction   ○ Waiting
```

- Badges: Waiting grey · Running blue with spinner · Done green · Skipped grey outline · Failed red.
- Detail line: duration (`finished_at - started_at`, or elapsed time while running) and `*_error`.
- **Derived state:** a pure function maps a `file_metadata` document to three row
  states. If a stage's status is null but that stage's artifact exists, it shows
  **Done**. This covers files processed before this feature.
- **Non-workspace files** (`vfs_scope != "workspace"`): show a single line,
  "Background processing applies to workspace files only", instead of the stage rows.

### Polling

A `dcc.Interval` (existing pattern) re-reads `file_metadata` every 5 s while any stage is
Waiting or Running. It is disabled once every stage is Done, Skipped or Failed, and
after 30 minutes on the page.

### New revision

The existing reset in `file_details.py` (around line 2392, which clears stale
artifact IDs) also clears all 12 status attributes.

### Retry

- Shown only on Failed stages, and only to users with edit access to the file.
- It clears all 12 status attributes and republishes `file.uploaded` through the
  webapp's existing upload-complete publish path. The pipeline restarts from conversion.
  Re-converting is cheap and avoids rebuilding downstream event payloads in the webapp.

**Prerequisite (verify before building Retry):** workflow instance IDs are
deterministic (`transform-<file_metadata_id>`, `index-<file_metadata_id>`). The
indexer documents that scheduling a duplicate ID "will fail gracefully". If Dapr
refuses to reschedule a completed instance ID, Retry and revision re-processing
silently do nothing. If confirmed, change instance IDs to include revision and
attempt (or purge before scheduling) in each service. The deterministic ID
currently provides at-least-once dedup, so the replacement must preserve
dedup within a single attempt.

## 4. Rollout

Each step ships independently; null status already renders as Waiting/Done.

1. **Schema**: add the 12 attributes in `platform40-appwrite` provisioning and run it.
2. **Services** (in parallel): status writes in transformer, indexer and extractor.
3. **Webapp**: Pipeline block, polling, and the revision reset.
4. **Retry**: after the workflow-ID prerequisite is verified or fixed.

## 5. Testing

- **Per service (unit):** running at start; done / skipped / failed with the mapped
  message at end; a failed status write does not break the pipeline.
- **Webapp (unit):** the derived-state function, covering null status with an
  artifact (Done), null status without one (Waiting), the non-workspace scope, and the
  polling stop condition.
- **End to end on the test server (3.90.155.157):**
  - `.txt` upload: Conversion Skipped → Indexing Done → Extraction Done.
  - `.docx` upload: all stages Done.
  - Forced indexing failure (e.g. large file under rate limit): Indexing Failed with the
    friendly message; Retry → all stages Done.
