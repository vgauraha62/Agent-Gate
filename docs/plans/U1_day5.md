 Policy Integration Documentation                                                                                                                                                             
                                                                                                                                                                                              
 ### System Architecture Overview                                                                                                                                                             
                                                                                                                                                                                              
 ```                                                                                                                                                                                          
   ┌─────────────────────────────────────────────────────────────────┐                                                                                                                        
   │                    HTTP Request                                   │                                                                                                                      
   └─────────────┬─────────────────────┬─────────────────────────────┘                                                                                                                        
                 │                     │                                                                                                                                                      
                 ▼                     ▼                                                                                                                                                      
       ┌──────────────────┐   ┌──────────────────┐                                                                                                                                            
       │  Zero-Copy Parser   │   │  Headers Map      │                                                                                                                                        
       └────────┬─────────┘   └────────┬───────────┘                                                                                                                                          
                │                     │                                                                                                                                                       
                │             Parse Content-Length                                                                                                                                            
                ▼                     ▼                                                                                                                                                       
       ┌─────────────────────────────────────────────┐                                                                                                                                        
       │              RequestContext                   │                                                                                                                                      
       │  • AgentID (from JWT token)                  │                                                                                                                                       
       │  • HTTP Method                                │                                                                                                                                      
       │  • Request Path                               │                                                                                                                                      
       │  • Content-Length                             │                                                                                                                                      
       └───────────────┬─────────────────────────────┘                                                                                                                                        
                       │                                                                                                                                                                      
                       ▼                                                                                                                                                                      
       ┌─────────────────────────────────────────────┐                                                                                                                                        
       │        Auth Middleware (Unit 4)              │                                                                                                                                       
       │  • Extract Bearer from Authorization header  │                                                                                                                                       
       │  • Call JWT.parse()                          │                                                                                                                                       
       │  • Call JWT.verify()                         │                                                                                                                                       
       │  • Return Agent or 401                       │                                                                                                                                       
       └───────────────┬─────────────────────────────┘                                                                                                                                        
                       │                                                                                                                                                                      
                       ▼                                                                                                                                                                      
       ┌─────────────────────────────────────────────┐                                                                                                                                        
       │        Policy Integration (Unit 5)           │                                                                                                                                       
       │  • Evaluate policies                         │                                                                                                                                       
       │  • Return 200 (allow) or 403 (deny)         │                                                                                                                                        
       │  • Include policy ID in response             │                                                                                                                                       
       └───────────────┬─────────────────────────────┘                                                                                                                                        
                       │                                                                                                                                                                      
                       ▼                                                                                                                                                                      
       ┌─────────────────────────────────────────────┐                                                                                                                                        
       │        Audit Logger (Unit 6)                 │                                                                                                                                       
       │  • Log decision to ring buffer               │                                                                                                                                       
       └───────────────┬─────────────────────────────┘                                                                                                                                        
                       │                                                                                                                                                                      
                       ▼                                                                                                                                                                      
       ┌─────────────────────────────────────────────┐                                                                                                                                        
       │        Metrics Counters (Unit 7)             │                                                                                                                                       
       │  • Increment request_total/allowed/denied    │                                                                                                                                       
       │  • Gauge for active_connections              │                                                                                                                                       
       └─────────────────────────────────────────────┘                                                                                                                                        
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 ### Security Patterns                                                                                                                                                                        
                                                                                                                                                                                              
 #### 1. Zero-Copy Request Parsing                                                                                                                                                            
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const RequestLine = struct {                                                                                                                                                               
       method: []u8,                                                                                                                                                                          
       path: []u8,                                                                                                                                                                            
   };                                                                                                                                                                                         
                                                                                                                                                                                              
   // Parse request line in-place, no heap allocation                                                                                                                                         
   const parseRequestLine = fn (buffer: []u8) ?RequestLine {                                                                                                                                  
       const parts = std.mem.split(u8, buffer, " ");                                                                                                                                          
       return _ = try parseParts(buffer, parts);                                                                                                                                              
   }                                                                                                                                                                                          
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 #### 2. Arena Allocation for Headers                                                                                                                                                         
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const RequestHeaders = struct {                                                                                                                                                            
       entries: []Header = undefined,                                                                                                                                                         
   };                                                                                                                                                                                         
                                                                                                                                                                                              
   // Use SecurityArena for all parsing                                                                                                                                                       
   const SecurityArena = try getArena();                                                                                                                                                      
                                                                                                                                                                                              
   // Arena-allocated maps for headers                                                                                                                                                        
   const headers = try arena.map(u8, HeaderEntry);                                                                                                                                            
   defer securityArena.deinit(arena);                                                                                                                                                         
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 #### 3. Error Propagation Chain                                                                                                                                                              
                                                                                                                                                                                              
 ┌────────────────┬───────────┬───────────────────────┐                                                                                                                                       
 │ Error Type     │ HTTP Code │ Message               │                                                                                                                                       
 ├────────────────┼───────────┼───────────────────────┤                                                                                                                                       
 │ Parse error    │ 400       │ Bad Request           │                                                                                                                                       
 ├────────────────┼───────────┼───────────────────────┤                                                                                                                                       
 │ JWT invalid    │ 401       │ Unauthorized          │                                                                                                                                       
 ├────────────────┼───────────┼───────────────────────┤                                                                                                                                       
 │ Policy deny    │ 403       │ Forbidden             │                                                                                                                                       
 ├────────────────┼───────────┼───────────────────────┤                                                                                                                                       
 │ Internal error │ 500       │ Internal Server Error │                                                                                                                                       
 └────────────────┴───────────┴───────────────────────┘                                                                                                                                       
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 ### Implementation Checklist                                                                                                                                                                 
                                                                                                                                                                                              
 - Unit 1: HTTP Request Parser (modify http.zig)                                                                                                                                              
     - Zero-copy parse request line                                                                                                                                                           
     - Arena-allocate headers map                                                                                                                                                             
     - Handle body reading with content-length                                                                                                                                                
     - Test scenarios: happy path, edge cases, error paths                                                                                                                                    
 - Unit 4: JWT Authentication Middleware (create auth_middleware.zig)                                                                                                                         
     - Extract Bearer token from Authorization header                                                                                                                                         
     - Call JWT.parse() with SecurityArena                                                                                                                                                    
     - Call JWT.verify() with Secret key                                                                                                                                                      
     - Return Agent on success, 401 on failure                                                                                                                                                
 - Unit 5: Policy Integration (modify http.zig)                                                                                                                                               
     - Build RequestContext from request + agent                                                                                                                                              
     - Call PolicyEngine.evaluate()                                                                                                                                                           
     - Return 200 (allow) or 403 (deny)                                                                                                                                                       
     - Include matched policy ID in response                                                                                                                                                  
 - Unit 6: Audit Logger (modify logger.zig)                                                                                                                                                   
     - Define LogEntry struct                                                                                                                                                                 
     - Implement ring buffer                                                                                                                                                                  
     - Export function for debugging                                                                                                                                                          
 - Unit 7: Metrics Counters (modify prometheus.zig)                                                                                                                                           
     - Atomic counters                                                                                                                                                                        
     - Export function for /metrics                                                                                                                                                           
 - Unit 8: HTTP Endpoints (create endpoints)                                                                                                                                                  
     - GET /health - no auth required                                                                                                                                                         
     - POST /check - auth + policy evaluation                                                                                                                                                 
     - GET /metrics - Prometheus format                                                                                                                                                       
 - Unit 9: Integration Tests (create test files)                                                                                                                                              
     - End-to-end tests                                                                                                                                                                       
     - Concurrency tests                                                                                                                                                                      
     - Memory safety tests                                                                                                                                                                    
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 ### Memory Safety & Thread Safety                                                                                                                                                            
                                                                                                                                                                                              
 #### Ring Buffer Implementation                                                                                                                                                              
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const AuditLogger = struct {                                                                                                                                                               
       buffer: []*LogEntry,                                                                                                                                                                   
       capacity: usize,                                                                                                                                                                       
       next_index: usize,                                                                                                                                                                     
                                                                                                                                                                                              
       fn log(self: *AuditLogger, entry: LogEntry) void {                                                                                                                                     
           if (self.next_index >= self.capacity) {                                                                                                                                            
               // Wrap around                                                                                                                                                                 
           }                                                                                                                                                                                  
           self.buffer[self.next_index] = entry;                                                                                                                                              
           self.next_index = (self.next_index + 1) % self.capacity;                                                                                                                           
       }                                                                                                                                                                                      
   };                                                                                                                                                                                         
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 #### Thread-Safe Metrics                                                                                                                                                                     
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const Metrics = struct {                                                                                                                                                                   
       request_total: atomic.atomic_u64 = 0,                                                                                                                                                  
       allowed_total: atomic.atomic_u64 = 0,                                                                                                                                                  
       denied_total: atomic.atomic_u64 = 0,                                                                                                                                                   
                                                                                                                                                                                              
       fn increment(self: Metrics, type: u32) void {                                                                                                                                          
           switch (type) {                                                                                                                                                                    
               .requests => self.request_total.fetch_add(u64, .monotonic) += 1,                                                                                                               
               .allowed => self.allowed_total.fetch_add(u64, .monotonic) += 1,                                                                                                                
               .denied => self.denied_total.fetch_add(u64, .monotonic) += 1,                                                                                                                  
           }                                                                                                                                                                                  
       }                                                                                                                                                                                      
   };                                                                                                                                                                                         
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 ### Integration Test Strategy                                                                                                                                                                
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const IntegrationTest = struct {                                                                                                                                                           
       fn test() void {                                                                                                                                                                       
           const server = try Server.init();                                                                                                                                                  
           defer server.deinit();                                                                                                                                                             
                                                                                                                                                                                              
           const request = try createCheckRequest();                                                                                                                                          
           const response = try server.do_request(request);                                                                                                                                   
                                                                                                                                                                                              
           try assert.equal(response.status, 200);                                                                                                                                            
           try assert.equal(response.headers.get("X-Policy"), "policy_v1");                                                                                                                   
                                                                                                                                                                                              
           server.deinit();                                                                                                                                                                   
       }                                                                                                                                                                                      
   };                                                                                                                                                                                         
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 ### Security Validation Checklist                                                                                                                                                            
                                                                                                                                                                                              
 - Zero copy parsing doesn't leak memory                                                                                                                                                      
 - Arena allocation is properly tracked                                                                                                                                                       
 - JWT token validation prevents replay attacks                                                                                                                                               
 - Policy evaluation is deterministic                                                                                                                                                         
 - Metrics are thread-safe                                                                                                                                                                    
 - Audit log is complete and ordered                                                                                                                                                          
 - Concurrency doesn't race conditions                                                                                                                                                        
 - Memory safety verified                                                                                                                                                                     
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 ### Next Steps                                                                                                                                                                               
                                                                                                                                                                                              
 1. Implement http.zig with zero-copy parsing                                                                                                                                                 
 2. Create auth_middleware.zig for JWT validation                                                                                                                                             
 3. Implement policy_engine.zig for policy decisions                                                                                                                                          
 4. Add logging and metrics hooks                                                                                                                                                             
 5. Write unit tests for each component                                                                                                                                                       
 6. Integrate into main http.zig server loop                                                                                                                                                  
 7. Test with various HTTP requests                                                                                                                                                           
 8. Verify memory safety and thread safety                                                                                                                                                    
 9. Document and push to version control                                                                                                                                                      
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 ### Key Security Considerations                                                                                                                                                              
                                                                                                                                                                                              
 - Memory Safety: Use SecurityArena for all allocations to prevent leaks                                                                                                                      
 - Thread Safety: Use atomic operations for metrics                                                                                                                                           
 - Zero-Copy: Minimize heap allocations for HTTP parsing                                                                                                                                      
 - Audit Trail: Maintain complete request audit logs                                                                                                                                          
 - Metrics: Export Prometheus-compatible metrics                                                                                                                                              
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
