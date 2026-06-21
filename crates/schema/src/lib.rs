pub mod agent;
pub mod job;
pub mod skill;
pub mod task;
pub mod vendor;

// Re-export the most-used task types at crate root for ergonomic imports.
pub use task::{
    QueueStats, SemVer, Task, TaskKind, TaskPriority, TaskQueue, TaskSession,
    TaskStatus, Versioned,
};
// Re-export vendor types for indexer + MCP server.
pub use vendor::{AstSymbol, FileAst, FileRecord, VendorConfig, VendorRow, VendorsConfig};
