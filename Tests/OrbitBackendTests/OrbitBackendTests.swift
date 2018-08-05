import XCTest
import OrbitCompilerUtils
import OrbitFrontend
@testable import OrbitBackend
import cllvm
import LLVM
import SwiftyJSON

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
    
    func buildApiTestFile(testFileName: String) throws {
        let session = OrbitSession(callingConvention: LLVMCallingConvention())
        
        let source = SourceResolver(session: session)
        let bundle = Bundle(for: type(of: self))
        let path = bundle.path(forResource: testFileName, ofType: "api")!
        let code = try source.execute(input: path)
        
        let reader = APIMapReader(session: session)
        let result = try reader.execute(input: JSON(parseJSON: code))
        
        print(result)
    }
    
    func findApiFileOnPaths() throws {
        let session = OrbitSession(orbPaths: [URL(fileURLWithPath: "/usr/local/lib/Orbit/")], callingConvention: LLVMCallingConvention())
        
        let path = try session.findApiMap(named: "Orb.Core.api")
        let source = SourceResolver(session: session)
        let code = try source.execute(input: path.path)
        let reader = APIMapReader(session: session)
        let apiMap = try reader.execute(input: JSON(parseJSON: code))
        
        print(apiMap.export())
    }
    
    func buildTestFile(testFileName: String) throws {
        let session = OrbitSession(orbPaths: [URL(fileURLWithPath: "/usr/local/lib/Orbit/"), URL(fileURLWithPath: "/Users/davie/dev/other/Orb/")], callingConvention: LLVMCallingConvention())
        
        let source = SourceResolver(session: session)
//        let bundle = Bundle(for: type(of: self))
//        let path = bundle.path(forResource: testFileName, ofType: "orb")!
        let code = try source.execute(input: "/Users/davie/dev/other/Orb/Foo.orb") //path)
        
        let lexer = Lexer(session: session)
        let annotationTokens = try lexer.execute(input: code)
        let annotationParser = ParseContext(session: session, callingConvention: LLVMCallingConvention(), rules: [
            AnnotationRule()
        ], skipUnexpected: true)
        
        let annotatedRoot = try annotationParser.execute(input: annotationTokens)
        let annotationExpressions = (annotatedRoot as! RootExpression).body as! [AnnotationExpression]
        let annotations = annotationExpressions.map { PhaseAnnotation(expression: $0, identifier: $0.annotationName.value) }
        
        let parser = ParseContext.bootstrapParser(session: session)
        let tokens = try lexer.execute(input: code)
        let ast = try parser.execute(input: tokens)
        
        annotations.forEach {
            (ast as! RootExpression).annotate(annotation: $0)
        }
        
        let root = ast as! RootExpression
        var prog = root.body[0] as! ProgramExpression
        
        let dependencyGraph = DependencyGraph(session: session)
        let ordered = try dependencyGraph.execute(input: root)
        
        prog = ProgramExpression(apis: ordered, startToken: prog.startToken)
        root.body = [prog]
        
        let typeExtractor = TypeExtractor(session: session)
        let apis = try typeExtractor.execute(input: root)

//        let writer = APIMapWriter(session: session)
        
//        apis.forEach {
//            let res = try! writer.execute(input: $0)
//
//            print(res)
//        }
        
        let typeResolver = TypeResolver(session: session)
        let result = try typeResolver.execute(input: (ast as! RootExpression, apis))
        
        let typeChecker = TypeChecker(session: session)
        let verified = try typeChecker.execute(input: result)
        
        print(verified.toJson())
        
        let llvm = LLVMGen(session: session)
        let gen = try llvm.execute(input: (ast as! RootExpression, apis))

        gen.forEach {
            $0.context.gen()
        }
        
//        typeChecker.session.popAll()
        
        session.popAll()
    }
    
    func testResolve() {
        do {
            //try findApiFileOnPaths()
            //try buildApiTestFile(testFileName: "test1")
            try buildTestFile(testFileName: "test1")
        } catch let ex as OrbitError {
            print(ex.message)
        } catch let ex {
            print(ex)
        }
    }
}
