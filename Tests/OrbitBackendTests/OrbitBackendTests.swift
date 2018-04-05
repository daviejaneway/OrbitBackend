import XCTest
import OrbitCompilerUtils
import OrbitFrontend
@testable import OrbitBackend
import cllvm
import LLVM

class OrbitBackendTests : XCTestCase {
    
//    func parseTestFile(testFileName: String) throws -> Parser.OutputType {
//        let source = SourceResolver()
//        let lexer = Lexer()
//        let parser = Parser()
//
//        let bundle = Bundle(for: type(of: self))
//        let path = bundle.path(forResource: testFileName, ofType: "orb")!
//
//        let code = try source.execute(input: path)
//        let tokens = try lexer.execute(input: code)
//        let ast = try parser.execute(input: tokens)
//
//        return ast
//    }
    
    func buildTestFile(testFileName: String) throws {
        let session = OrbitSession()
        
        let source = SourceResolver(session: session)
        let lexer = Lexer(session: session)
        let parser = ParseContext.bootstrapParser(session: session)
        
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: testFileName, ofType: "orb")!
        
        let code = try source.execute(input: path)
        let tokens = try lexer.execute(input: code)
        let ast = try parser.execute(input: tokens)
        
        let typeExtractor = TypeExtractor(session: session)
        let types = try typeExtractor.execute(input: ast as! RootExpression)
        
        let typeResolver = TypeResolver(session: session)
        let result = try typeResolver.execute(input: (ast as! RootExpression, types))
        
        let typeChecker = TypeChecker(session: session)
        let verified = try typeChecker.execute(input: (ast as! RootExpression, types))
        
        print(verified.toJson())
        typeChecker.session.popAll()
        
        let llvm = LLVMGen(session: session)
        let gen = try llvm.execute(input: (ast as! RootExpression))
        
        gen.forEach {
            $0.context.gen()
        }
        
//        let typer = SimpleTyper()
//        let typeMap = try typer.execute(input: ast as! RootExpression) as! ProgramType
//
//        let expander = TypeExpander()
//        let expandedTypeMap = try expander.execute(input: typeMap)
//
//        print(expandedTypeMap.debug(level: 0))
//
//        let unique = Uniqueness()
//        let prog = try unique.execute(input: expandedTypeMap)
//
//        let llvm = LLVMGen()
//        let context = try llvm.execute(input: prog)
//
//        context.gen()
        
//        var context = try nr.execute(input: ast.body as! [APIExpression])
//        context = try mr.execute(input: context)
//
//        context = try traitResolver.execute(input: context)
//
//        let tr = TypeResolver()
//        context = try tr.execute(input: context)
//
//        let gen = LLVMGenerator()
//        let result = try gen.execute(input: context)
//
//        result.dump()
//        try result.print(to: "/Users/davie/dev/other/Orb/test.ll")
//
//        try result.verify()
//
//        try TargetMachine().emitToFile(module: result, type: .assembly, path: "/Users/davie/dev/other/Orb/test.s")
    }
    
    func testResolve() {
        do {
            try buildTestFile(testFileName: "test1")
        } catch let ex as OrbitError {
            print(ex.message)
        } catch let ex {
            print(ex)
        }
    }
}
