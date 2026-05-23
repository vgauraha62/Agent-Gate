//! Entry point for audit integration tests.
//!
//! Wrapper at `src/` level so the module root is `src/`, allowing
//! `@import("../config.zig")` in `src/audit/` files to resolve correctly
//! (within module path rather than outside it).
const _ = @import("audit/integration_test.zig");
