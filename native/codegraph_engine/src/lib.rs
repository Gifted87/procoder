mod parser;
mod ast_node;

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

#[rustler::nif]
fn hello() -> &'static str {
    "Hello from Rust!"
}

rustler::init!("Elixir.ProCoder.Search.CodeGraph.Native", [
    add, 
    hello,
    parser::parse_source
]);
