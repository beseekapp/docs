# Workspace entities view — design

Date: 2026-10-05 · Status: design approved in chat, awaiting spec review · Follows `2026-10-04-insight-knowledge-graph-design.md` (merged: extractor #4, seeker #3, webapp #11)

## Goal

Let a workspace member see everything the extractor knows about the workspace as a filterable entity table, and explore from any entity as a graph, on the Insights page.

Today the graph is reachable only per file, inside the insight drawer.

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Shape | Entity directory (table) + search box + type chips, with a graph pane seeded from the selected row. Ideas 2 + 4 + 5 of the brainstorm; the directory's filter box *is* the search box. |
| 2 | Placement | **Cards \| Entities** segmented control on the existing Insights page, not a new nav page. Reuses the membership guard, `insights-data-store` and the insight drawer. |
| 3 | Search | Case-insensitive substring on the entity label, client-side. Not semantic. |
| 4 | Long lists | Top 50 by file count after filtering, with "Showing 50 of N — narrow the filter". No pagination. |
| 5 | Chips | Apply to the table and to the page graph. Not to the drawer graph. |
| 6 | Graph callbacks | Drawer and page graphs share one set of callbacks via pattern-matching ids. |
| 7 | PRs | Every PR carries the label `GRAPH_INSIGHT` so the set is merged together. |

Out of scope: semantic entity search (seeker `/v1/tools/search-entities` via Weaviate), pagination of the table, chips on the drawer graph, a file-to-file map, editing the graph.

## 1. Seeker — `POST /v1/graph/entities`

Router `platform40-seeker/src/application/api/graph.py`, next to `/document` and `/expand`.

```
request:  {workspace_id: str}
response: {entities: [{id, label, type, file_count: int}]}
```

`Neo4jSearchClient.workspace_entities(workspace_id) -> list[dict]`:

```
MATCH (e:Entity {workspace_id: $workspace_id})-[:MENTIONED_IN]->(d:Document {workspace_id: $workspace_id})
WITH e, count(DISTINCT d) AS file_count
RETURN e, file_count
ORDER BY file_count DESC, e.label
LIMIT 5000
```

- Rows map through the existing `_entity_view` plus `file_count`.
- `LIMIT 5000` is a safety cap, not a feature (`ponytail:` comment; add offset paging if a workspace hits it).
- Neo4j failure → `503 {"detail": "graph unavailable"}`, same as the other two endpoints.
- Internal only (Dapr); webapp checks membership.

Models in `domain/models/graph_view.py`: `WorkspaceEntitiesRequest`, `EntityCount`, `EntityList`.

## 2. Webapp — Entities view

### 2.1 Page switch (`pages/insights.py`)

- `dmc.SegmentedControl(id="insights-view", data=[Cards, Entities], value="cards")` in the page header `Group`, beside the "Active only" switch.
- The existing filter row, grid and pagination are wrapped in `html.Div(id="insights-cards-section")`; the new view is `html.Div(id="insights-entities-section", style={"display": "none"})`. One callback toggles the two `display` styles. Nothing is re-rendered on switch.

### 2.2 Layout (`components/insight/application/entities_view.py`)

Two columns (`dmc.Grid`, 5/7 on `md`, stacked on `base`):

**Left — directory**
- `dcc.Store(id="entities-store")` — the seeker list, loaded once when the view is first shown (Input `insights-view` == "entities" and the store is empty).
- `dmc.TextInput(id="entities-filter", placeholder="Filter entities…")`.
- `dmc.ChipGroup(id="entities-types", multiple=True)` with one `dmc.Chip` per entry of `ENTITY_TYPES` (`insight_graph.py`), all selected by default, chip colour = the type colour. Entities whose type is not in `ENTITY_TYPES` are always shown (no "Other" chip).
- `html.Div(id="entities-table")` → `dmc.Table` with columns Entity · Type (coloured `dmc.Badge`) · Files. Rows are `html.Tr(id={"type": "entity-row", "index": <entity id>}, n_clicks=0)` with pointer cursor; the selected row is highlighted.
- Footer text: "Showing 50 of N — narrow the filter" when truncated, "N entities" otherwise, "No entities extracted yet" when the list is empty.

**Right — graph**
- `dcc.Store(id={"type": "kg-graph-target", "scope": "page"})`, `dmc.Text(id={"type": "kg-graph-status", "scope": "page"})`, `dmc.Button("Reset", id={"type": "kg-graph-reset", "scope": "page"})`, `cyto.Cytoscape(id={"type": "kg-graph", "scope": "page"})`, `render_legend()`.
- Empty state (no row selected): status "Select an entity to see its graph".

**Pure functions** (tested without Dash):
- `filter_entities(entities, text, types, limit=50) -> (rows, total)`.
- `hidden_types_stylesheet(selected_types) -> list` = `STYLESHEET` + `{"selector": '[type = "<T>"]', "style": {"display": "none"}}` for each type of `ENTITY_TYPES` not selected. Cytoscape hides the edges of hidden nodes by itself.

### 2.3 Shared graph callbacks (`pages/insights.py`)

The drawer's three graph callbacks are converted to pattern-matching ids; `insight_graph.py` renames its ids to `{"type": "kg-graph…", "scope": "drawer"}`. No other file references the old ids.

| Callback | Ids | Behaviour |
|---|---|---|
| load / reset | `MATCH` on target, reset, graph, status | target has `file_metadata_id` → `/v1/graph/document` minus the file node (as today); target has `entity_id` → `/v1/graph/expand`; neither → `[]`. |
| expand on entity tap | `MATCH` | as today; `without_file` only when the target has a `file_metadata_id`. |
| open insight on file tap | `Input({"type": "kg-graph", "scope": ALL}, "tapNodeData")`, `ctx.triggered_id` picks the graph; outputs drawer `opened=True`, title, content (`allow_duplicate=True`) | as today, plus opening the drawer, which the page scope needs. |

New page-only callbacks:
- row click (`Input({"type": "entity-row", "index": ALL}, "n_clicks")`, `ctx.triggered_id`) → writes `{workspace_id, entity_id}` to the page target store, which triggers load; also re-renders the table with the row highlighted.
- filter / chips change → `entities-table` children via `filter_entities`, and page graph `stylesheet` via `hidden_types_stylesheet`.
- view switch to "entities" with empty store → `fetch_entities` (new in `adapters/graph_service.py`, same `_post` helper) → store.

All callbacks that call seeker run `require_workspace_membership` first, as the existing graph callbacks do.

### 2.4 Errors

- Seeker/Neo4j down when loading the list → table area shows "Graph unavailable right now"; the Cards view is unaffected.
- Seeker down on row click or expand → status "Graph unavailable right now" (existing copy).
- File node whose insight is not in `insights-data-store` → "No insight for this file yet" (existing copy).
- More than 100 nodes after expanding → existing cap and "Showing the first 100 — Reset to start over".

## 3. Tests

Seeker (`tests/`, existing graph mock pattern):
- Workspace isolation: entities of workspace B never returned for A.
- Response shape: `file_count` is the number of distinct documents.
- Neo4j error → 503.

Webapp (`tests/test_insight_graph_service.py` or a sibling):
- `filter_entities`: case-insensitive substring; type filter; unknown types always shown; `limit` with correct `total`.
- Existing merge/cap tests unchanged.
- UI verified in the browser on the test server (no UI unit tests).

## 4. Rollout

| Step | Repo | Branch | Ships | Safe alone because |
|---|---|---|---|---|
| 1 | docs | `spec/workspace-entities-view` | this spec | — |
| 2 | platform40-seeker | `feat/entities-view` from `main` | `/v1/graph/entities` | new endpoint only |
| 3 | platform40-webapp | `feat/entities-view` from `main` (already contains #11) | Entities view, shared graph callbacks | missing endpoint → "Graph unavailable right now" |

**Labelling.** The label `GRAPH_INSIGHT` does not exist yet in any repo. Create it once per repo and apply it to every PR of this set:

```
for r in docs platform40-seeker platform40-webapp; do
  gh label create GRAPH_INSIGHT -R beseekapp/$r --color 7950f2 --description "Knowledge graph insight work — merge the set together" --force
done
gh pr create --label GRAPH_INSIGHT …
```

Deploy seeker then webapp with `docs/scripts/deploy-to-remote.sh <service>`; after the seeker deploy run `docs/scripts/workers-on-remote.sh set 1 seeker` (a redeploy resets workers to the Dockerfile value).

**End-to-end check on the test server:**
1. Insights → Entities: table lists the extracted entities, most-mentioned first; chip and text filters narrow it.
2. Click "Acme Corp": the graph shows it, its neighbours and the files that mention them.
3. Untick "Date": date nodes and their edges disappear from the graph and the table.
4. Click a file node: its insight opens in the drawer; the drawer's own graph still works.
5. Stop Neo4j briefly: Entities view shows "Graph unavailable right now"; Cards view works; start Neo4j.

**Size:** seeker ½ day, webapp 1 day.
