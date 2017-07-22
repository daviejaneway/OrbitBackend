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
                "type Main() " +
                
                "(Main) main (x Int) (Int) " +
                    "return x + x " +
                "... " +
            "... ")
        
        do {
            let expr = try parser.execute(input: tokens)
            let tm = try tr.execute(input: expr)
            
            let api = expr.body[0] as! APIExpression
            let gen = LLVMGenerator(apiName: api.name.value)
            let result = try gen.execute(input: (typeMap: tm, ast: api))
            
            result.dump()
            
            try result.verify()
        } catch let ex as OrbitError {
            print(ex.message)
        } catch let ex {
            print(ex)
        }
    }
}
