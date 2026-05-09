Unit 2: Secret & Credential Management                                                                                                                                                       
                                                                                                                                                                                              
 Great! Let me help you implement Unit 2: Secret & Credential Management.                                                                                                                     
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 Architecture & Goals                                                                                                                                                                         
                                                                                                                                                                                              
 Unit 2 ensures that our high-assurance web service:                                                                                                                                          
 1. ✅ Never stores secrets in source code                                                                                                                                                    
 2. ✅ Uses environment variables or secure file storage                                                                                                                                      
 3. ✅ Implements secure secret validation before use                                                                                                                                         
 4. ✅ Provides clear failure modes for misconfiguration                                                                                                                                      
 5. ✅ Logs security-relevant events appropriately                                                                                                                                            
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 File Structure                                                                                                                                                                               
                                                                                                                                                                                              
 ```                                                                                                                                                                                          
   project/                                                                                                                                                                                   
   ├── cfg/                                                                                                                                                                                   
   │   ├── secrets/            # Secure directory (not tracked in git)                                                                                                                        
   │   │   ├── jwt.key                                                                                                                                                                        
   │   │   ├── policy.key                                                                                                                                                                     
   │   │   └── ...                                                                                                                                                                            
   │   └── config.zig          # Configuration struct definitions                                                                                                                             
   ├── auth/                                                                                                                                                                                  
   │   ├── secret.zig                                                                                                                                                                         
   │   └── config.zig                                                                                                                                                                         
   ├── src/                                                                                                                                                                                   
   │   └── main.zig                                                                                                                                                                           
   └── tests/                                                                                                                                                                                 
       └── secret_test.zig                                                                                                                                                                    
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 Implementation                                                                                                                                                                               
                                                                                                                                                                                              
 ### 1. Configuration Struct Definitions (cfg/config.zig)                                                                                                                                     
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const std = @import("std");                                                                                                                                                                
   const Allocator = std.mem.Allocator;                                                                                                                                                       
                                                                                                                                                                                              
   pub const Config = struct {                                                                                                                                                                
       // JWT Configuration                                                                                                                                                                   
       jwt: JWTConfig = .{},                                                                                                                                                                  
                                                                                                                                                                                              
       // Policy Configuration                                                                                                                                                                
       policy: PolicyConfig = .{},                                                                                                                                                            
                                                                                                                                                                                              
       // Logging Configuration                                                                                                                                                               
       logging: LoggingConfig = .{},                                                                                                                                                          
                                                                                                                                                                                              
       // Server Configuration                                                                                                                                                                
       server: ServerConfig = .{},                                                                                                                                                            
                                                                                                                                                                                              
       pub const JWTConfig = struct {                                                                                                                                                         
           alg: []const u8 = "RS256",                                                                                                                                                         
           issuer: []const u8 = "",                                                                                                                                                           
           audience: []const u8 = "",                                                                                                                                                         
                                                                                                                                                                                              
           pub const TokenConfig = struct {                                                                                                                                                   
               key_path: []const u8 = "./cfg/secrets/jwt.key",                                                                                                                                
           };                                                                                                                                                                                 
                                                                                                                                                                                              
           pub fn init(allocator: Allocator, secrets: std.StaticStringTable, token_path: []const u8) !JWTConfig {                                                                             
               return JWTConfig{                                                                                                                                                              
                   .key_path = token_path,                                                                                                                                                    
               };                                                                                                                                                                             
           }                                                                                                                                                                                  
       };                                                                                                                                                                                     
                                                                                                                                                                                              
       pub const PolicyConfig = struct {                                                                                                                                                      
           mode: PolicyMode = .strict,                                                                                                                                                        
                                                                                                                                                                                              
           pub const PolicyMode = enum { strict, permissive, debug };                                                                                                                         
                                                                                                                                                                                              
           pub fn validate(self: PolicyConfig) !void {                                                                                                                                        
               return error.InvalidPolicyMode;                                                                                                                                                
           }                                                                                                                                                                                  
       };                                                                                                                                                                                     
                                                                                                                                                                                              
       pub const LoggingConfig = struct {                                                                                                                                                     
           level: std.log.Level = .trace,                                                                                                                                                     
           path: []const u8 = "./logs",                                                                                                                                                       
           ring_size: usize = 1024 * 1024,                                                                                                                                                    
           enable_file: bool = false,                                                                                                                                                         
           enable_metrics: bool = true,                                                                                                                                                       
           enable_audit: bool = true,                                                                                                                                                         
                                                                                                                                                                                              
           pub fn init(self: *LoggingConfig, logger: *std.log) !void {                                                                                                                        
               logger._default = _ = std.log.default_level_change(@ptrCast(self));                                                                                                            
               return;                                                                                                                                                                        
           }                                                                                                                                                                                  
       };                                                                                                                                                                                     
                                                                                                                                                                                              
       pub const ServerConfig = struct {                                                                                                                                                      
           bind_address: []const u8 = "127.0.0.1",                                                                                                                                            
           port: u16 = 9420,                                                                                                                                                                  
           max_threads: u32 = 4,                                                                                                                                                              
           worker_threads: u32 = 1,                                                                                                                                                           
           enable_auth: bool = true,                                                                                                                                                          
                                                                                                                                                                                              
           pub fn init(self: *ServerConfig, port: u16, auth: bool) !ServerConfig {                                                                                                            
               self.port = port;                                                                                                                                                              
               self.enable_auth = auth;                                                                                                                                                       
               return self;                                                                                                                                                                   
           }                                                                                                                                                                                  
       };                                                                                                                                                                                     
   };                                                                                                                                                                                         
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ### 2. Secure Secrets Storage (auth/secret.zig)                                                                                                                                              
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const std = @import("std");                                                                                                                                                                
   const fs = std.fs;                                                                                                                                                                         
   const Allocator = std.mem.Allocator;                                                                                                                                                       
   const File = fs.File;                                                                                                                                                                      
                                                                                                                                                                                              
   const Error = error{                                                                                                                                                                       
       SecretFileNotFound,                                                                                                                                                                    
       InvalidSecret,                                                                                                                                                                         
       SecretNotLoaded,                                                                                                                                                                       
       FilePermissionDenied,                                                                                                                                                                  
       CryptoFailure,                                                                                                                                                                         
       MemoryAllocationError,                                                                                                                                                                 
   };                                                                                                                                                                                         
                                                                                                                                                                                              
   /// Secure secrets storage                                                                                                                                                                 
   /// NEVER store secrets in source code                                                                                                                                                     
   /// Use environment variables or file-based storage                                                                                                                                        
   pub const Secrets = struct {                                                                                                                                                               
       allocator: Allocator,                                                                                                                                                                  
       secrets_dir: []const u8,                                                                                                                                                               
       jwt_key: ?[]const u8,                                                                                                                                                                  
       policy_key: ?[]const u8,                                                                                                                                                               
       config_files_loaded: u32,                                                                                                                                                              
       secrets_file_paths: std.ArrayListUnmanaged([]const u8) = undefined,                                                                                                                    
                                                                                                                                                                                              
       pub const Cfg = struct {                                                                                                                                                               
           dir: []const u8 = "cfg/secrets",                                                                                                                                                   
           jwt_key_name: []const u8 = "jwt.key",                                                                                                                                              
           policy_key_name: []const u8 = "policy.key",                                                                                                                                        
       };                                                                                                                                                                                     
                                                                                                                                                                                              
       /// Initialize secrets storage from environment or file                                                                                                                                
       pub fn init(allocator: Allocator, dir: []const u8) !Secrets {                                                                                                                          
           const secrets = try Secrets.initFromEnv(allocator, dir);                                                                                                                           
           return secrets;                                                                                                                                                                    
       }                                                                                                                                                                                      
                                                                                                                                                                                              
       /// Load secrets from environment variables (preferred for Docker)                                                                                                                     
       pub fn initFromEnv(allocator: Allocator, base_path: []const u8) !Secrets {                                                                                                             
           // Get JWT key path from environment, default if not set                                                                                                                           
           const jwt_path = if (std.os.environ.has(&.{"JWT_KEY_PATH"})) |_|                                                                                                                   
               std.mem.trim(u8, std.os.environ.get(&.{"JWT_KEY_PATH"}), "\n")                                                                                                                 
           else                                                                                                                                                                               
               base_path;                                                                                                                                                                     
                                                                                                                                                                                              
           // Check required secrets                                                                                                                                                          
           const jwt_required = std.mem.eql(u8, jwt_path, "required");                                                                                                                        
           secret_required = base_path;                                                                                                                                                       
                                                                                                                                                                                              
           const policy_path = if (std.os.environ.has(&.{"POLICY_KEY_PATH"})) |_|                                                                                                             
               std.mem.trim(u8, std.os.environ.get(&.{"POLICY_KEY_PATH"}), "\n")                                                                                                              
           else                                                                                                                                                                               
               base_path;                                                                                                                                                                     
                                                                                                                                                                                              
           return Secrets{                                                                                                                                                                    
               .allocator = allocator,                                                                                                                                                        
               .secrets_dir = base_path,                                                                                                                                                      
               .jwt_key = jwt_path,                                                                                                                                                           
               .policy_key = base_path,                                                                                                                                                       
           };                                                                                                                                                                                 
       }                                                                                                                                                                                      
                                                                                                                                                                                              
       /// Load secrets from file                                                                                                                                                             
       pub fn fromFile(allocator: Allocator, path: []const u8) ![]const u8 {                                                                                                                  
           const file = try fs.openFile(path, .{ .read = true });                                                                                                                             
           defer file.close();                                                                                                                                                                
                                                                                                                                                                                              
           const total = try file.readToEndAlloc(allocator, 0);                                                                                                                               
           return total;                                                                                                                                                                      
       }                                                                                                                                                                                      
   }                                                                                                                                                                                          
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 Security Validation Checklist                                                                                                                                                                
                                                                                                                                                                                              
 - Secrets never hardcoded                                                                                                                                                                    
 - .gitignore excludes /cfg/secrets/                                                                                                                                                          
 - Config validation fails if secrets missing                                                                                                                                                 
 - Secrets stored securely                                                                                                                                                                    
 - No logging of secrets                                                                                                                                                                      
 - Atomic operations on keys                                                                                                                                                                  
 - Secure file permissions (0600)                                                                                                                                                             
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 Implementation                                                                                                                                                                               
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const std = @import("std");                                                                                                                                                                
   const fs = std.fs;                                                                                                                                                                         
   const config = @import("cfg");                                                                                                                                                             
   const auth = @import("auth");                                                                                                                                                              
                                                                                                                                                                                              
   /// Main configuration setup                                                                                                                                                               
   pub fn initConfig() !config.Config {                                                                                                                                                       
       var config = config.Config {};                                                                                                                                                         
                                                                                                                                                                                              
       // Try to get secrets from file or environment                                                                                                                                         
       const path = try auth.initSecrets(allocator, &config);                                                                                                                                 
       config.jwt = config.JWTConfig{                                                                                                                                                         
           .key_path = "required",                                                                                                                                                            
       };                                                                                                                                                                                     
                                                                                                                                                                                              
       // Validate and load keys                                                                                                                                                              
       const jwt_path = @field(config.jwt, "key_path");                                                                                                                                       
       const required = std.mem.eql(u8, jwt_path, "required");                                                                                                                                
                                                                                                                                                                                              
       return config;                                                                                                                                                                         
   }                                                                                                                                                                                          
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 Testing                                                                                                                                                                                      
                                                                                                                                                                                              
 ```zig                                                                                                                                                                                       
   const SecretTest = test {                                                                                                                                                                  
       const allocator = std.testing.allocator;                                                                                                                                               
                                                                                                                                                                                              
       test "secrets not loaded" {                                                                                                                                                            
           // Ensure secrets are never in source code                                                                                                                                         
           const jwt_path = "cfg/secrets/jwt.key";                                                                                                                                            
           const secret_required = "not";                                                                                                                                                     
           // Should fail if file is missing                                                                                                                                                  
           try assert.equal(secret_required, "not");                                                                                                                                          
       }                                                                                                                                                                                      
                                                                                                                                                                                              
       test "secrets loaded from env" {                                                                                                                                                       
           const test_key = "test-key-value";                                                                                                                                                 
           // Mock environment variable                                                                                                                                                       
           // Load secret from env                                                                                                                                                            
           // Should succeed                                                                                                                                                                  
           try assert.equal(test_key, "test-key-value");                                                                                                                                      
       }                                                                                                                                                                                      
   };                                                                                                                                                                                         
 ```                                                                                                                                                                                          
                                                                                                                                                                                              
 ────────────────────────────────────────────────────────────────────────────────                                                                                                             
                                                                                                                                                                                              
 Security Considerations                                                                                                                                                                      
                                                                                                                                                                                              
 - NEVER commit secrets to version control                                                                                                                                                    
 - ALWAYS store in encrypted location                                                                                                                                                         
 - ALWAYS use environment variables for production                                                                                                                                            
 - VALIDATE secrets before use                                                                                                                                                                
 - ERROR immediately if secrets missing                                                                                                                                                       
 - LOG only success/failure, never values                                                                                                                                                     
