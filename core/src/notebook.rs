// .ipynb v4 parser/writer.
// We use serde_json::Value for cells/metadata to round-trip unknown fields exactly.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CellType {
    Code,
    Markdown,
    Raw,
}

impl CellType {
    pub fn as_str(&self) -> &'static str {
        match self {
            CellType::Code => "code",
            CellType::Markdown => "markdown",
            CellType::Raw => "raw",
        }
    }
    pub fn from_str(s: &str) -> Self {
        match s {
            "markdown" => CellType::Markdown,
            "raw" => CellType::Raw,
            _ => CellType::Code,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Notebook {
    pub nbformat: i64,
    pub nbformat_minor: i64,
    pub metadata: Value, // arbitrary JSON object preserved verbatim
    pub cells: Vec<Cell>,
}

#[derive(Debug, Clone)]
pub struct Cell {
    pub id: String,
    pub cell_type: CellType,
    pub source: String, // joined from source array
    pub execution_count: Option<u64>,
    pub outputs: Vec<Value>, // verbatim output objects
    pub metadata: Value,
    pub extra: Map<String, Value>, // any unknown fields preserved
}

impl Notebook {
    pub fn empty() -> Self {
        Self {
            nbformat: 4,
            nbformat_minor: 5,
            metadata: json!({
                "kernelspec": { "display_name": "Python 3", "language": "python", "name": "python3" },
                "language_info": { "name": "python" }
            }),
            cells: vec![Cell::new_code()],
        }
    }

    pub fn read(path: &Path) -> Result<Self> {
        // Treat a non-existent or empty file as a fresh notebook. Common
        // workflows like `touch foo.ipynb && nvim foo.ipynb` would otherwise
        // hit the json parser with zero bytes and fail with a confusing
        // "EOF while parsing" error.
        if !path.exists() {
            return Ok(Self::empty());
        }
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("read {}", path.display()))?;
        if raw.trim().is_empty() {
            return Ok(Self::empty());
        }
        Self::from_json(&raw)
    }

    pub fn from_json(raw: &str) -> Result<Self> {
        let v: Value = serde_json::from_str(raw)?;
        let obj = v.as_object().ok_or_else(|| anyhow!("not an object"))?;
        let nbformat = obj.get("nbformat").and_then(|v| v.as_i64()).unwrap_or(4);
        let nbformat_minor = obj.get("nbformat_minor").and_then(|v| v.as_i64()).unwrap_or(5);
        let metadata = obj.get("metadata").cloned().unwrap_or_else(|| json!({}));
        let cells_arr = obj
            .get("cells")
            .and_then(|v| v.as_array())
            .ok_or_else(|| anyhow!("missing cells array"))?;
        let mut cells = Vec::with_capacity(cells_arr.len());
        for c in cells_arr {
            cells.push(Cell::from_json(c)?);
        }
        Ok(Self {
            nbformat,
            nbformat_minor,
            metadata,
            cells,
        })
    }

    pub fn to_json_pretty(&self) -> Result<String> {
        let mut root = Map::new();
        let cells: Vec<Value> = self.cells.iter().map(|c| c.to_json()).collect();
        root.insert("cells".to_string(), Value::Array(cells));
        root.insert("metadata".to_string(), self.metadata.clone());
        root.insert("nbformat".to_string(), json!(self.nbformat));
        root.insert("nbformat_minor".to_string(), json!(self.nbformat_minor));
        let v = Value::Object(root);
        Ok(serde_json::to_string_pretty(&v)? + "\n")
    }

    pub fn write(&self, path: &Path) -> Result<()> {
        let s = self.to_json_pretty()?;
        std::fs::write(path, s).with_context(|| format!("write {}", path.display()))?;
        Ok(())
    }

    pub fn kernel_name(&self) -> Option<String> {
        self.metadata
            .get("kernelspec")
            .and_then(|k| k.get("name"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    }

    /// Best guess at the notebook's language. Tries kernelspec.language first,
    /// then falls back to language_info.name. Used to find a fallback kernel
    /// when the exact name from kernelspec.name isn't installed.
    pub fn kernel_language(&self) -> Option<String> {
        self.metadata
            .get("kernelspec")
            .and_then(|k| k.get("language"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                self.metadata
                    .get("language_info")
                    .and_then(|k| k.get("name"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
    }
}

impl Cell {
    pub fn new_code() -> Self {
        Self {
            id: new_cell_id(),
            cell_type: CellType::Code,
            source: String::new(),
            execution_count: None,
            outputs: Vec::new(),
            metadata: json!({}),
            extra: Map::new(),
        }
    }

    pub fn new_markdown(source: impl Into<String>) -> Self {
        Self {
            id: new_cell_id(),
            cell_type: CellType::Markdown,
            source: source.into(),
            execution_count: None,
            outputs: Vec::new(),
            metadata: json!({}),
            extra: Map::new(),
        }
    }

    pub fn from_json(v: &Value) -> Result<Self> {
        let obj = v.as_object().ok_or_else(|| anyhow!("cell not object"))?;
        let cell_type = obj
            .get("cell_type")
            .and_then(|v| v.as_str())
            .map(CellType::from_str)
            .unwrap_or(CellType::Code);
        let id = obj
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(new_cell_id);
        let source = match obj.get("source") {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Array(arr)) => arr
                .iter()
                .filter_map(|v| v.as_str())
                .collect::<Vec<&str>>()
                .join(""),
            _ => String::new(),
        };
        let execution_count = obj
            .get("execution_count")
            .and_then(|v| v.as_u64());
        let outputs = obj
            .get("outputs")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let metadata = obj.get("metadata").cloned().unwrap_or_else(|| json!({}));
        // Preserve any other fields verbatim
        let mut extra = Map::new();
        for (k, v) in obj {
            if !matches!(
                k.as_str(),
                "cell_type" | "id" | "source" | "execution_count" | "outputs" | "metadata"
            ) {
                extra.insert(k.clone(), v.clone());
            }
        }
        Ok(Self {
            id,
            cell_type,
            source,
            execution_count,
            outputs,
            metadata,
            extra,
        })
    }

    pub fn to_json(&self) -> Value {
        let mut obj = Map::new();
        obj.insert("cell_type".to_string(), json!(self.cell_type.as_str()));
        obj.insert("id".to_string(), json!(self.id));
        obj.insert("metadata".to_string(), self.metadata.clone());
        // source as array of lines (Jupyter convention) — keep trailing \n on all but last
        obj.insert("source".to_string(), source_to_array(&self.source));
        if matches!(self.cell_type, CellType::Code) {
            obj.insert(
                "execution_count".to_string(),
                self.execution_count
                    .map(|n| json!(n))
                    .unwrap_or(Value::Null),
            );
            obj.insert("outputs".to_string(), Value::Array(self.outputs.clone()));
        }
        for (k, v) in &self.extra {
            obj.insert(k.clone(), v.clone());
        }
        Value::Object(obj)
    }
}

fn source_to_array(src: &str) -> Value {
    if src.is_empty() {
        return Value::Array(vec![]);
    }
    let mut lines: Vec<String> = src.split_inclusive('\n').map(|s| s.to_string()).collect();
    if lines.is_empty() {
        lines.push(src.to_string());
    }
    Value::Array(lines.into_iter().map(Value::String).collect())
}

fn new_cell_id() -> String {
    // Jupyter cell ids are short opaque strings; use first 8 hex of UUID
    let u = uuid::Uuid::new_v4();
    let s = u.simple().to_string();
    s[..8].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_roundtrip() {
        let nb = Notebook::empty();
        let j = nb.to_json_pretty().unwrap();
        let parsed = Notebook::from_json(&j).unwrap();
        assert_eq!(parsed.cells.len(), 1);
    }

    #[test]
    fn parse_minimal_ipynb() {
        let raw = r#"{
            "cells": [
                {"cell_type":"code","id":"abc","metadata":{},"source":["print('hi')\n","print('again')"],"execution_count":1,"outputs":[]}
            ],
            "metadata":{},
            "nbformat":4,"nbformat_minor":5
        }"#;
        let nb = Notebook::from_json(raw).unwrap();
        assert_eq!(nb.cells[0].source, "print('hi')\nprint('again')");
        assert_eq!(nb.cells[0].execution_count, Some(1));
    }

    #[test]
    fn source_array_roundtrip() {
        let nb = Notebook::from_json(
            r#"{"cells":[{"cell_type":"code","id":"x","metadata":{},"source":"a\nb\nc","execution_count":null,"outputs":[]}],"metadata":{},"nbformat":4,"nbformat_minor":5}"#,
        ).unwrap();
        let js = nb.to_json_pretty().unwrap();
        assert!(js.contains("\"a\\n\""));
        assert!(js.contains("\"b\\n\""));
        assert!(js.contains("\"c\""));
    }

    #[test]
    fn execution_metadata_survives_save_load() {
        // The execution-timing display persists across save+reopen by riding
        // in cell metadata.execution (the same keys JupyterLab records). The
        // save path must NOT drop it.
        let src = r#"{"cells":[{"cell_type":"code","id":"x","metadata":{"execution":{"iopub.execute_input":"2026-06-13T00:00:00.100Z","shell.execute_reply":"2026-06-13T00:00:00.450Z"}},"source":"x=1","execution_count":4,"outputs":[]}],"metadata":{},"nbformat":4,"nbformat_minor":5}"#;
        let nb = Notebook::from_json(src).unwrap();
        let js = nb.to_json_pretty().unwrap();
        assert!(js.contains("iopub.execute_input"), "execute_input stamp lost on save");
        assert!(js.contains("shell.execute_reply"), "execute_reply stamp lost on save");
        // and a second round-trip is stable
        let js2 = Notebook::from_json(&js).unwrap().to_json_pretty().unwrap();
        assert!(js2.contains("shell.execute_reply"));
    }
}
