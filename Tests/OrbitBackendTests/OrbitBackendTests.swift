import XCTest
import OrbitCompilerUtils
import OrbitFrontend
@testable import OrbitBackend
import cllvm
import LLVM

class OrbitBackendTests : XCTestCase {
    func parseTestFile(testFileName: String) throws -> (TypeResolver.OutputType, Parser.OutputType) {
        let source = SourceResolver()
        let lexer = Lexer()
        let parser = Parser()
        let tr = TypeResolver()
        
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: testFileName, ofType: "orb")!
        
        let code = try source.execute(input: path)
        let tokens = try lexer.execute(input: code)
        let ast = try parser.execute(input: tokens)
        let tm = try tr.execute(input: ast)
        
        return (typeMap: tm, ast: ast)
    }
    
    func testResolve() {
        do {
            let ast = try parseTestFile(testFileName: "test1")
            let api = ast.1.body[0] as! APIExpression
            let gen = LLVMGenerator(apiName: api.name.value)
            let result = try gen.execute(input: (typeMap: ast.0, ast: api))
            
            result.dump()
            
            try result.verify()
        } catch let ex as OrbitError {
            print(ex.message)
        } catch let ex {
            print(ex)
        }
    }
}
