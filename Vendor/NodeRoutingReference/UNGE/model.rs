use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;

pub type Id = Uuid;
pub type Properties = BTreeMap<String, serde_json::Value>;
pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("missing item: {0}")]
    Missing(String),
    #[error("duplicate item: {0}")]
    Duplicate(String),
    #[error("invalid graph: {0}")]
    Invalid(String),
    #[error("invalid properties: {0}")]
    Properties(String),
    #[error("graph contains a cycle")]
    Cycle,
    #[error("unsupported schema version: {0}")]
    Version(u32),
    #[error("serialization: {0}")]
    Json(#[from] serde_json::Error),
}

#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "name", rename_all = "snake_case")]
pub enum DataType {
    Bool,
    Int,
    Float,
    String,
    Json,
    Bytes,
    Image,
    Audio,
    Video,
    Tensor,
    Event,
    Any,
    Custom(String),
}
impl DataType {
    pub fn accepts(&self, source: &Self) -> bool {
        self == source || *self == Self::Any
    }
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Cardinality {
    Single,
    Multiple,
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Port {
    pub name: String,
    pub data_type: DataType,
    pub cardinality: Cardinality,
    pub required: bool,
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Node {
    pub id: Id,
    pub type_id: String,
    pub inputs: Vec<Port>,
    pub outputs: Vec<Port>,
    #[serde(default)]
    pub properties: Properties,
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Endpoint {
    pub node: Id,
    pub port: String,
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Edge {
    pub id: Id,
    pub from: Endpoint,
    pub to: Endpoint,
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Group {
    pub id: Id,
    pub label: String,
    pub nodes: BTreeSet<Id>,
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Graph {
    pub id: Id,
    pub name: String,
    // Ordered maps make documents and execution plans deterministic across runs.
    pub(crate) nodes: BTreeMap<Id, Node>,
    pub(crate) edges: BTreeMap<Id, Edge>,
    pub(crate) groups: BTreeMap<Id, Group>,
}
impl Default for Graph {
    fn default() -> Self {
        Self {
            id: Id::new_v4(),
            name: "Untitled".into(),
            nodes: BTreeMap::new(),
            edges: BTreeMap::new(),
            groups: BTreeMap::new(),
        }
    }
}
impl Graph {
    pub fn nodes(&self) -> &BTreeMap<Id, Node> {
        &self.nodes
    }
    pub fn edges(&self) -> &BTreeMap<Id, Edge> {
        &self.edges
    }
    pub fn groups(&self) -> &BTreeMap<Id, Group> {
        &self.groups
    }
    pub fn validate(&self) -> Result<()> {
        for (id, node) in &self.nodes {
            if *id != node.id {
                return Err(Error::Invalid("node key does not match id".into()));
            }
            for ports in [&node.inputs, &node.outputs] {
                let mut seen = BTreeSet::new();
                for p in ports {
                    if p.name.is_empty() || !seen.insert(&p.name) {
                        return Err(Error::Invalid("empty or duplicate port".into()));
                    }
                }
            }
        }
        let mut occupied = BTreeSet::new();
        let mut connections = BTreeSet::new();
        for (id, edge) in &self.edges {
            if *id != edge.id {
                return Err(Error::Invalid("edge key does not match id".into()));
            }
            let from = self
                .nodes
                .get(&edge.from.node)
                .ok_or_else(|| Error::Missing(edge.from.node.to_string()))?;
            let to = self
                .nodes
                .get(&edge.to.node)
                .ok_or_else(|| Error::Missing(edge.to.node.to_string()))?;
            let output = from
                .outputs
                .iter()
                .find(|p| p.name == edge.from.port)
                .ok_or_else(|| Error::Missing(edge.from.port.clone()))?;
            let input = to
                .inputs
                .iter()
                .find(|p| p.name == edge.to.port)
                .ok_or_else(|| Error::Missing(edge.to.port.clone()))?;
            if !input.data_type.accepts(&output.data_type) {
                return Err(Error::Invalid(
                    "incompatible port types; use an explicit converter node".into(),
                ));
            }
            if !connections.insert((edge.from.node, &edge.from.port, edge.to.node, &edge.to.port)) {
                return Err(Error::Invalid("duplicate connection".into()));
            }
            if input.cardinality == Cardinality::Single
                && !occupied.insert((edge.to.node, &edge.to.port))
            {
                return Err(Error::Invalid("single input is already connected".into()));
            }
        }
        for (id, group) in &self.groups {
            if *id != group.id || group.nodes.iter().any(|n| !self.nodes.contains_key(n)) {
                return Err(Error::Invalid("invalid group membership".into()));
            }
        }
        self.layers()?;
        Ok(())
    }
    /// Topological dependency analysis; independent nodes share a layer.
    pub fn layers(&self) -> Result<Vec<Vec<Id>>> {
        let index = GraphIndex::new(self);
        let mut degree: BTreeMap<_, _> = self
            .nodes
            .keys()
            .map(|id| (*id, index.incoming.get(id).map_or(0, Vec::len)))
            .collect();
        let mut ready: Vec<_> = degree
            .iter()
            .filter_map(|(id, d)| (*d == 0).then_some(*id))
            .collect();
        let mut result = Vec::new();
        let mut visited = 0;
        while !ready.is_empty() {
            visited += ready.len();
            let mut next = Vec::new();
            for id in &ready {
                for edge in index.outgoing.get(id).into_iter().flatten() {
                    let target = self.edges[edge].to.node;
                    let d = degree
                        .get_mut(&target)
                        .ok_or_else(|| Error::Missing(target.to_string()))?;
                    *d -= 1;
                    if *d == 0 {
                        next.push(target);
                    }
                }
            }
            next.sort();
            result.push(ready);
            ready = next;
        }
        if visited != self.nodes.len() {
            return Err(Error::Cycle);
        }
        Ok(result)
    }
}
#[derive(Debug, Default)]
pub struct GraphIndex {
    pub incoming: std::collections::HashMap<Id, Vec<Id>>,
    pub outgoing: std::collections::HashMap<Id, Vec<Id>>,
}
impl GraphIndex {
    pub fn new(graph: &Graph) -> Self {
        let mut index = Self::default();
        for edge in graph.edges.values() {
            index
                .incoming
                .entry(edge.to.node)
                .or_default()
                .push(edge.id);
            index
                .outgoing
                .entry(edge.from.node)
                .or_default()
                .push(edge.id);
        }
        index
    }
    pub fn downstream(&self, graph: &Graph, root: Id) -> BTreeSet<Id> {
        let mut visited = BTreeSet::new();
        let mut stack = vec![root];
        while let Some(id) = stack.pop() {
            if visited.insert(id) {
                stack.extend(
                    self.outgoing
                        .get(&id)
                        .into_iter()
                        .flatten()
                        .map(|edge| graph.edges[edge].to.node),
                );
            }
        }
        visited
    }
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}
impl Rect {
    pub fn valid(self) -> bool {
        [
            self.x,
            self.y,
            self.width,
            self.height,
            self.x + self.width,
            self.y + self.height,
        ]
        .iter()
        .all(|v| v.is_finite() && v.abs() <= 1.0e9)
            && self.width > 0.0
            && self.height > 0.0
    }
    pub fn intersects(self, other: Self) -> bool {
        self.x <= other.x + other.width
            && self.x + self.width >= other.x
            && self.y <= other.y + other.height
            && self.y + self.height >= other.y
    }
}
impl Default for Rect {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            width: 180.0,
            height: 90.0,
        }
    }
}
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Document {
    pub schema_version: u32,
    pub engine_version: String,
    #[serde(default)]
    pub plugin_versions: BTreeMap<String, String>,
    pub(crate) graph: Graph,
    #[serde(default)]
    pub(crate) placement: BTreeMap<Id, Rect>,
}
impl Default for Document {
    fn default() -> Self {
        Self {
            schema_version: 1,
            engine_version: env!("CARGO_PKG_VERSION").into(),
            plugin_versions: BTreeMap::new(),
            graph: Graph::default(),
            placement: BTreeMap::new(),
        }
    }
}
impl Document {
    pub fn graph(&self) -> &Graph {
        &self.graph
    }
    pub fn placement(&self) -> &BTreeMap<Id, Rect> {
        &self.placement
    }
    pub fn validate(&self) -> Result<()> {
        if self.schema_version != 1 {
            return Err(Error::Version(self.schema_version));
        }
        self.graph.validate()?;
        if self
            .placement
            .iter()
            .any(|(id, r)| !self.graph.nodes.contains_key(id) || !r.valid())
        {
            return Err(Error::Invalid("invalid placement".into()));
        }
        Ok(())
    }
    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        let doc: Self = serde_json::from_slice(bytes)?;
        doc.validate()?;
        Ok(doc)
    }
    pub fn to_json(&self) -> Result<String> {
        self.validate()?;
        Ok(serde_json::to_string_pretty(self)?)
    }
}
