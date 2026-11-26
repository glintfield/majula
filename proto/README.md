# proto

The client/server API schema will live here, as Protobuf served with Connect RPC
([ADR 0003](../docs/adr/0003-api-schema.md)). Code is generated with buf: `protoc-gen-es` for the
server, and BSR remote plugins pinned to exact versions for the Swift and Kotlin clients.
Generated code is committed. Where the client code is generated and packaged is job 2.3's.

There's no schema, `buf.yaml` or codegen here yet. A later job adds the first schema.
