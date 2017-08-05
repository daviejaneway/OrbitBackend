import XCTest
import OrbitCompilerUtils
import OrbitFrontend
@testable import OrbitBackend
import cllvm
import LLVM

class OrbitBackendTests : XCTestCase {
    
    func parseTestFile(testFileName: String) throws -> Parser.OutputType {
        let source = SourceResolver()
        let lexer = Lexer()
        let parser = Parser()
        
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: testFileName, ofType: "orb")!
        
        let code = try source.execute(input: path)
        let tokens = try lexer.execute(input: code)
        let ast = try parser.execute(input: tokens)
        
        return ast
    }
    
    func buildTestFile(testFileName: String) throws { //-> (TypeResolver.OutputType, Parser.OutputType) {
        let source = SourceResolver()
        let lexer = Lexer()
        let parser = Parser()
        let nr = NameResolver()
        
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: testFileName, ofType: "orb")!
        
        let code = try source.execute(input: path)
        let tokens = try lexer.execute(input: code)
        let ast = try parser.execute(input: tokens)
        
        let context = try nr.execute(input: ast.body as! [APIExpression])
        
        let api = try context.mergeAPIs()
        
        let tr = TypeResolver()
        let tm = try tr.execute(input: api)
        
        let gen = LLVMGenerator(apiName: api.name.value)
        let result = try gen.execute(input: (context: context, typeMap: tm, ast: api))
        
        result.dump()
        
        try result.verify()
    }
    
    func testResolve() {
        do {
            //let ast = try buildTestFile(testFileName: "hierarchy")
            
            try buildTestFile(testFileName: "test1")
            
//            for api in (ast.1.body as! [APIExpression]) {
//                //let api = ast.1.body[0] as! APIExpression
//                let gen = LLVMGenerator(apiName: api.name.value, isMain: (api.within?.value == "Main"))
//                let result = try gen.execute(input: (typeMap: ast.0, ast: api))
//                
//                result.dump()
//                
//                try result.verify()
//            }
        } catch let ex as OrbitError {
            print(ex.message)
        } catch let ex {
            print(ex)
        }
    }
    
    func testResolveAPIHierarchy() {
        do {
            let ast = try parseTestFile(testFileName: "hierarchy")
            
            let resolver = NameResolver()
            
            let context = try resolver.execute(input: ast.body as! [APIExpression])
            
            print(context.typeNameMap)
        } catch let ex {
            print((ex as! OrbitError).message)
        }
    }
}
