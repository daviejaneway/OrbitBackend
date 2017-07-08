import XCTest
import OrbitCompilerUtils
import OrbitFrontend
@testable import OrbitBackend

class OrbitBackendTests: XCTestCase {
    func testResolve() {
        let lexer = Lexer()
        let parser = Parser()
        let tr = TypeResolver()
        
        let tokens = try! lexer.execute(input:
            "api Test " +
                "type Foo() " +
                
                "(self Foo) bar (x Int) (Int) " +
                    "return x * 2 " +
                "... " +
            "... ")
        
        do {
            let expr = try parser.execute(input: tokens)
            let result = try tr.execute(input: expr)
            
            print(result)
        } catch let ex as OrbitError {
            print(ex.message)
        } catch {
            
        }
    }
}
