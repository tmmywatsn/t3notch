#!/bin/bash
# Drives T3 Notch through a full run without needing T3 Code.
#
#   ./Scripts/fixture.sh setup     build the fixture database
#   ./Scripts/fixture.sh seed      fill it with demo threads (for screenshots)
#   ./Scripts/fixture.sh run       start a run  (notch shows the working bar)
#   ./Scripts/fixture.sh finish    finish it    (completion banner)
#   ./Scripts/fixture.sh fail      fail it      (failure banner)
#   ./Scripts/fixture.sh ask       ask a question (attention card)
#
# Then point the app at it:
#   T3NOTCH_USERDATA=/tmp/t3notch-fixture "build/T3 Notch.app/Contents/MacOS/T3Notch"
set -euo pipefail

DIR="${T3NOTCH_FIXTURE:-/tmp/t3notch-fixture}"
DB="$DIR/state.sqlite"
now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
ago() { date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z; }

case "${1:-setup}" in
setup)
  rm -rf "$DIR"
  mkdir -p "$DIR"
  sqlite3 "$DB" "PRAGMA journal_mode=WAL;" > /dev/null
  sqlite3 "$DB" <<'SQL'
CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL,
  workspace_root TEXT NOT NULL, scripts_json TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT, default_model_selection_json TEXT,
  default_thread_env_mode TEXT, favicon_path TEXT);
CREATE TABLE projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
  title TEXT NOT NULL, branch TEXT, worktree_path TEXT, latest_turn_id TEXT,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT,
  runtime_mode TEXT NOT NULL DEFAULT 'full-access', interaction_mode TEXT NOT NULL DEFAULT 'default',
  model_selection_json TEXT, archived_at TEXT, latest_user_message_at TEXT,
  pending_approval_count INTEGER NOT NULL DEFAULT 0, pending_user_input_count INTEGER NOT NULL DEFAULT 0,
  has_actionable_proposed_plan INTEGER NOT NULL DEFAULT 0, settled_override TEXT, settled_at TEXT,
  snoozed_until TEXT, snoozed_at TEXT, title_regeneration_request_id TEXT,
  title_regeneration_started_at TEXT, pinned_at TEXT, pin_order_key TEXT,
  linked_pull_request_json TEXT, unsettled_at TEXT);
CREATE TABLE projection_thread_sessions (thread_id TEXT PRIMARY KEY, status TEXT NOT NULL,
  provider_name TEXT, provider_session_id TEXT, provider_thread_id TEXT, active_turn_id TEXT,
  last_error TEXT, updated_at TEXT NOT NULL, runtime_mode TEXT NOT NULL DEFAULT 'full-access',
  provider_instance_id TEXT);
CREATE TABLE projection_turns (row_id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL,
  turn_id TEXT, pending_message_id TEXT, assistant_message_id TEXT, state TEXT NOT NULL,
  requested_at TEXT NOT NULL, started_at TEXT, completed_at TEXT, checkpoint_turn_count INTEGER,
  checkpoint_ref TEXT, checkpoint_status TEXT, checkpoint_files_json TEXT NOT NULL,
  source_proposed_plan_thread_id TEXT, source_proposed_plan_id TEXT);
CREATE TABLE projection_thread_activities (activity_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  turn_id TEXT, tone TEXT NOT NULL, kind TEXT NOT NULL, summary TEXT NOT NULL,
  payload_json TEXT NOT NULL, created_at TEXT NOT NULL, sequence INTEGER);
CREATE TABLE projection_pending_approvals (request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  turn_id TEXT, status TEXT NOT NULL, decision TEXT, created_at TEXT NOT NULL, resolved_at TEXT);
CREATE TABLE orchestration_events (sequence INTEGER PRIMARY KEY, aggregate_kind TEXT NOT NULL,
  stream_id TEXT NOT NULL, event_type TEXT NOT NULL, payload_json TEXT NOT NULL, occurred_at TEXT NOT NULL);
SQL
  sqlite3 "$DB" <<SQL
INSERT INTO projection_projects (project_id,title,workspace_root,scripts_json,created_at,updated_at)
  VALUES ('p1','storefront','/tmp/storefront','[]','$(now)','$(now)');
INSERT INTO projection_threads (thread_id,project_id,title,branch,created_at,updated_at,model_selection_json)
  VALUES ('t1','p1','Refactor the checkout flow','feature/checkout','$(now)','$(now)','{"model":"claude-opus-5"}');
INSERT INTO projection_thread_sessions (thread_id,status,provider_name,updated_at)
  VALUES ('t1','ready','claudeAgent','$(now)');
SQL
  echo "fixture ready at $DIR"
  ;;
run)
  sqlite3 "$DB" <<SQL
UPDATE projection_thread_sessions SET status='running', active_turn_id='turn1', last_error=NULL, updated_at='$(now)' WHERE thread_id='t1';
DELETE FROM projection_turns WHERE thread_id='t1';
INSERT INTO projection_turns (thread_id,turn_id,state,requested_at,started_at,checkpoint_files_json)
  VALUES ('t1','turn1','running','$(ago 95)','$(ago 95)','[]');
INSERT OR REPLACE INTO projection_threads (thread_id,project_id,title,branch,created_at,updated_at,model_selection_json)
  VALUES ('t1','p1','Refactor the checkout flow','feature/checkout','$(ago 95)','$(now)','{"model":"claude-opus-5"}');
INSERT OR REPLACE INTO projection_projects (project_id,title,workspace_root,scripts_json,created_at,updated_at)
  VALUES ('p1','storefront','/Users/you/Projects/storefront','[]','$(now)','$(now)');
INSERT OR REPLACE INTO projection_thread_activities (activity_id,thread_id,turn_id,tone,kind,summary,payload_json,created_at,sequence)
  VALUES ('a1','t1','turn1','tool','tool.started','Command run started',
    '{"itemType":"command_execution","toolCallId":"c1","status":"inProgress","detail":"Bash: pnpm test --filter checkout","data":{"toolName":"Bash"}}','$(now)',1);
UPDATE projection_threads SET updated_at='$(now)' WHERE thread_id='t1';
SQL
  echo "running"
  ;;
finish)
  sqlite3 "$DB" <<SQL
UPDATE projection_thread_sessions SET status='ready', active_turn_id=NULL, updated_at='$(now)' WHERE thread_id='t1';
UPDATE projection_turns SET state='completed', completed_at='$(now)',
  checkpoint_files_json='[{"path":"src/checkout/cart.ts","kind":"modified","additions":120,"deletions":34},{"path":"src/checkout/pay.ts","kind":"modified","additions":62,"deletions":6}]'
  WHERE thread_id='t1';
UPDATE projection_threads SET updated_at='$(now)' WHERE thread_id='t1';
SQL
  echo "finished"
  ;;
fail)
  sqlite3 "$DB" <<SQL
UPDATE projection_thread_sessions SET status='stopped', active_turn_id=NULL,
  last_error='Claude runtime stream failed.', updated_at='$(now)' WHERE thread_id='t1';
UPDATE projection_turns SET state='error', completed_at='$(now)' WHERE thread_id='t1';
UPDATE projection_threads SET updated_at='$(now)' WHERE thread_id='t1';
SQL
  echo "failed"
  ;;
seed)
  # A believable set of threads for screenshots and demos.
  sqlite3 "$DB" <<SQL
DELETE FROM projection_threads; DELETE FROM projection_thread_sessions;
DELETE FROM projection_turns;   DELETE FROM projection_thread_activities;
DELETE FROM projection_projects;

INSERT INTO projection_projects (project_id,title,workspace_root,scripts_json,created_at,updated_at) VALUES
  ('p1','storefront','/Users/you/Projects/storefront','[]','$(now)','$(now)'),
  ('p2','design-system','/Users/you/Projects/design-system','[]','$(now)','$(now)');

INSERT INTO projection_threads (thread_id,project_id,title,branch,created_at,updated_at,model_selection_json,pending_user_input_count) VALUES
  ('t1','p1','Refactor the checkout flow','feature/checkout','$(ago 900)','$(now)','{"model":"claude-opus-5"}',0),
  ('s2','p2','Tidy the design tokens','main','$(ago 600)','$(now)','{"model":"composer-1"}',0),
  ('s3','p1','Migrate the orders table','feature/orders','$(ago 1200)','$(now)','{"model":"gpt-6-astra"}',1),
  ('s4','p1','Add webhook retries','main','$(ago 4000)','$(ago 1800)','{"model":"claude-opus-5"}',0);

INSERT INTO projection_thread_sessions (thread_id,status,provider_name,active_turn_id,updated_at) VALUES
  ('t1','running','claudeAgent','r1','$(now)'),
  ('s2','running','cursor','r2','$(now)'),
  ('s3','ready','codex',NULL,'$(now)'),
  ('s4','ready','claudeAgent',NULL,'$(ago 1800)');

INSERT INTO projection_turns (thread_id,turn_id,state,requested_at,started_at,completed_at,checkpoint_files_json) VALUES
  ('t1','r1','running','$(ago 134)','$(ago 134)',NULL,'[]'),
  ('s2','r2','running','$(ago 47)','$(ago 47)',NULL,'[]'),
  ('s3','r3','completed','$(ago 400)','$(ago 400)','$(ago 300)','[]'),
  ('s4','r4','completed','$(ago 2000)','$(ago 2000)','$(ago 1800)','[{"path":"src/webhooks/retry.ts","additions":88,"deletions":12}]');

INSERT INTO projection_thread_activities (activity_id,thread_id,turn_id,tone,kind,summary,payload_json,created_at,sequence) VALUES
  ('a1','t1','r1','tool','tool.started','Command run started','{"itemType":"command_execution","toolCallId":"c1","status":"inProgress","detail":"Bash: pnpm test --filter checkout","data":{"toolName":"Bash"}}','$(now)',10),
  ('a2','t1','r1','tool','tool.completed','File change','{"itemType":"file_change","toolCallId":"c0","status":"completed","data":{"item":{"changes":[{"path":"src/checkout/cart.ts"}]}}}','$(ago 20)',9),
  ('a3','t1','r1','info','context-window.updated','Context window updated','{"usedTokens":420000,"maxTokens":1000000}','$(now)',8),
  ('a4','t1','r1','info','turn.plan.updated','Plan updated','{"plan":[{"step":"Extract the totals helper","status":"completed"},{"step":"Split the payment step","status":"pending"},{"step":"Backfill tests","status":"pending"}]}','$(now)',7),
  ('a5','s2','r2','tool','tool.started','File change','{"itemType":"file_change","toolCallId":"c2","status":"inProgress","data":{"item":{"changes":[{"path":"tokens/colour.css"}]}}}','$(now)',6),
  ('a6','s2','r2','info','context-window.updated','Context window updated','{"usedTokens":51000,"maxTokens":280000}','$(now)',5),
  ('a7','s3',NULL,'info','user-input.requested','User input requested','{"requestId":"q1","questions":[{"id":"q","header":"Migration order","question":"Should the backfill run before or after the index is created? After is faster but leaves a window of slow queries."}]}','$(now)',4);
SQL
  echo "seeded"
  ;;
ask)
  sqlite3 "$DB" <<SQL
INSERT OR REPLACE INTO projection_threads (thread_id,project_id,title,branch,created_at,updated_at,pending_user_input_count)
  VALUES ('t2','p1','Migrate the orders table','feature/orders','$(now)','$(now)',1);
INSERT OR REPLACE INTO projection_thread_sessions (thread_id,status,provider_name,updated_at)
  VALUES ('t2','ready','codex','$(now)');
INSERT OR REPLACE INTO projection_thread_activities (activity_id,thread_id,tone,kind,summary,payload_json,created_at,sequence)
  VALUES ('q1','t2','info','user-input.requested','User input requested',
    '{"requestId":"r1","questions":[{"id":"q","header":"Migration order","question":"Should the backfill run before or after the index is created?"}]}','$(now)',2);
SQL
  echo "asked"
  ;;
*)
  echo "usage: $0 {setup|seed|run|finish|fail|ask}" >&2
  exit 1
  ;;
esac
