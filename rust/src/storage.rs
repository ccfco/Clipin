use crate::models::*;
use rusqlite::Connection;
use std::sync::{Mutex, MutexGuard};

mod media;
mod read;
mod schema;
mod search;
mod write;

pub struct Storage {
    conn: Mutex<Connection>,
    image_dir: String,
}

impl Storage {
    /// 拿到底层 SQLite 连接的独占锁。
    /// 单进程内 SQLite 是单写者，靠这个 Mutex 串行化所有读写。
    /// `expect` 而不是 `unwrap`：mutex 中毒（持锁线程 panic）必须立即暴露而不是无声崩。
    #[inline]
    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().expect("storage connection mutex poisoned")
    }

    pub fn new(db_path: &str, image_dir: &str) -> Result<Self, ClipinError> {
        let conn = Connection::open(db_path)?;
        // WAL：写不阻塞读、fsync 只对 -wal 文件，剪贴板的「高频小写」场景代价显著降低
        // synchronous=NORMAL：依靠 WAL checkpoint 保证持久性，单进程语义足够，崩溃最坏丢最近几条
        // foreign_keys=ON：保留既有约束
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA foreign_keys = ON;",
        )?;
        let storage = Storage {
            conn: Mutex::new(conn),
            image_dir: image_dir.to_string(),
        };
        storage.init_schema()?;
        Ok(storage)
    }

    pub fn image_dir(&self) -> &str {
        &self.image_dir
    }

    /// 当前 schema 版本号，用于验证 migration 已正确执行
    #[cfg(test)]
    pub fn schema_version(&self) -> i32 {
        let conn = self.conn();
        // PRAGMA user_version 必返回一行整数；查询失败说明 DB 句柄异常，测试里应响亮
        // 失败而非 unwrap_or(0) 伪装成"版本 0"误导 migration 断言。
        conn.query_row("PRAGMA user_version", [], |r| r.get(0))
            .expect("PRAGMA user_version query failed")
    }
}

#[cfg(test)]
#[path = "storage_tests.rs"]
mod migration_tests;
