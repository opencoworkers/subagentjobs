-- Persisted task system: mirrors schema::Task / TaskQueue / TaskSession.
--
-- Design principles:
--   fact_tasks        — current state of each task (mutable, queryable)
--   dim_task_ast      — full JSONB snapshot for schema evolution / rich querying
--   event_task_states — append-only audit log; NEVER UPDATE, only INSERT
--
-- The existing crawl_task table (task-state-machine crate) is board-crawl-specific.
-- fact_tasks is the general-purpose system for all TaskSession tasks.

CREATE TABLE IF NOT EXISTS fact_tasks (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_name   TEXT        NOT NULL,            -- matches TaskSession.name
    schema_version TEXT        NOT NULL DEFAULT '0.1.0',
    content        TEXT        NOT NULL,            -- human-readable task description
    status         TEXT        NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','in_progress','completed','cancelled')),
    priority       TEXT        NOT NULL DEFAULT 'medium'
        CHECK (priority IN ('high','medium','low')),
    kind           JSONB       NOT NULL DEFAULT '{"kind":"todo"}',
    notes          TEXT,
    parent_id      UUID        REFERENCES fact_tasks(id),  -- for SubTask kind
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at     TIMESTAMPTZ,
    completed_at   TIMESTAMPTZ
);

-- Full serialised Task struct — allows schema evolution without ALTER TABLE.
-- Written once on task creation, updated when the task JSONB changes.
CREATE TABLE IF NOT EXISTS dim_task_ast (
    task_id        UUID        PRIMARY KEY REFERENCES fact_tasks(id),
    schema_version TEXT        NOT NULL DEFAULT '0.1.0',
    task_json      JSONB       NOT NULL,            -- serialised schema::Task
    session_json   JSONB,                           -- TaskSession snapshot at write time
    parsed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Append-only FSM event log.
-- Every state change gets a row; the table never has UPDATE or DELETE.
-- Reconstruct current state by MAX(occurred_at) GROUP BY task_id,
-- or replay the full history for debugging / audit.
CREATE TABLE IF NOT EXISTS event_task_states (
    id             BIGSERIAL   PRIMARY KEY,
    task_id        UUID        NOT NULL REFERENCES fact_tasks(id),
    from_state     TEXT,                            -- NULL for initial creation event
    to_state       TEXT        NOT NULL,
    agent_id       TEXT,                            -- process / MCP session identifier
    session_name   TEXT,                            -- TaskSession context
    reason         TEXT,                            -- why this transition happened
    context        JSONB,                           -- arbitrary metadata (error, sha256, …)
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_ft_session    ON fact_tasks(session_name);
CREATE INDEX IF NOT EXISTS idx_ft_status     ON fact_tasks(status);
CREATE INDEX IF NOT EXISTS idx_ft_priority   ON fact_tasks(priority);
CREATE INDEX IF NOT EXISTS idx_ft_kind       ON fact_tasks USING GIN(kind);
CREATE INDEX IF NOT EXISTS idx_ft_parent     ON fact_tasks(parent_id);
CREATE INDEX IF NOT EXISTS idx_ft_created    ON fact_tasks(created_at);

CREATE INDEX IF NOT EXISTS idx_eta_task      ON event_task_states(task_id);
CREATE INDEX IF NOT EXISTS idx_eta_to        ON event_task_states(to_state);
CREATE INDEX IF NOT EXISTS idx_eta_occurred  ON event_task_states(occurred_at);
CREATE INDEX IF NOT EXISTS idx_eta_session   ON event_task_states(session_name);

-- View: latest state per task (materialised by the event log)
CREATE OR REPLACE VIEW v_task_current_state AS
SELECT DISTINCT ON (task_id)
    task_id, to_state AS current_state, agent_id, occurred_at
FROM event_task_states
ORDER BY task_id, occurred_at DESC;
