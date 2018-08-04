//
//  JSON.swift
//  OrbitBackendPackageDescription
//
//  Created by Davie Janeway on 06/03/2018.
//

import Foundation
import OrbitFrontend
import SwiftyJSON

protocol JSONAwareExpression {
    func toJson() -> JSON
}

extension TypeIdentifierExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "TypeIdenfifier",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "value": self.value
        ]
    }
}

extension IdentifierExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "Identifier",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "value": self.value
        ]
    }
}

extension PairExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "IDTypePair",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "identifier": self.name.toJson(),
            "type": self.type.toJson()
        ]
    }
}

extension TypeDefExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "TypeDef",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "value": self.name.value,
            "properties": self.properties.map { $0.toJson() }
        ]
    }
}

extension StaticSignatureExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "Signature",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "receiverType": self.receiverType.toJson(),
            "returnType": self.returnType?.toJson() ?? JSON.null,
            "parameters": self.parameters.map { $0.toJson() }
        ]
    }
}

extension IntLiteralExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "IntLiteral",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "value": self.value
        ]
    }
}

extension RealLiteralExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "RealLiteral",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "value": self.value
        ]
    }
}

extension UnaryExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "UnaryExpr",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "operator": "\(self.op.symbol) : \(self.op.position)",
            "value": Formatter.jsonify(expression: self.value)
        ]
    }
}

extension BinaryExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "BinaryExpr",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "operator": "\(self.op.symbol) : \(self.op.position)",
            "left": Formatter.jsonify(expression: self.left),
            "right": Formatter.jsonify(expression: self.right)
        ]
    }
}

extension InstanceCallExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "InstanceCall",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "receiver": Formatter.jsonify(expression: self.receiver),
            "method": self.methodName.toJson(),
            "arguments": self.args.map { Formatter.jsonify(expression: $0 as! AbstractExpression) }
        ]
    }
}

extension StaticCallExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "StaticCall",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "receiver": self.receiver.toJson(),
            "method": self.methodName.toJson(),
            "arguments": self.args.map { Formatter.jsonify(expression: $0 as! AbstractExpression) }
        ]
    }
}

extension ReturnStatement : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "Return",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "value": Formatter.jsonify(expression: self.value)
        ]
    }
}

extension DeferStatement : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "Defer",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "value": self.block.toJson()
        ]
    }
}

class Formatter {
    static func jsonify(expression: AbstractExpression) -> JSON {
        switch expression {
        case is IntLiteralExpression: return (expression as! IntLiteralExpression).toJson()
        case is RealLiteralExpression: return (expression as! RealLiteralExpression).toJson()
        case is UnaryExpression: return (expression as! UnaryExpression).toJson()
        case is BinaryExpression: return (expression as! BinaryExpression).toJson()
        case is InstanceCallExpression: return (expression as! InstanceCallExpression).toJson()
        case is StaticCallExpression: return (expression as! StaticCallExpression).toJson()
        case is IdentifierExpression: return (expression as! IdentifierExpression).toJson()
        case is TypeIdentifierExpression: return (expression as! TypeIdentifierExpression).toJson()
        case is ReturnStatement: return (expression as! ReturnStatement).toJson()
        case is DeferStatement: return (expression as! DeferStatement).toJson()
            
        default:
            return [
                "@node_type": "Unsupported \(type(of: expression))"
            ]
        }
    }
}

extension BlockExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "Block",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "body": self.body.map { Formatter.jsonify(expression: $0 as! AbstractExpression) },
            "return": (self.returnStatement == nil) ? JSON.null : Formatter.jsonify(expression: self.returnStatement!)
        ]
    }
}

extension MethodExpression : JSONAwareExpression {
    func toJson() -> JSON {
        return [
            "@node_type": "Method",
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() },
            "signature": self.signature.toJson(),
            "body": self.body.toJson()
        ]
    }
}

extension APIExpression : JSONAwareExpression {
    func toJson() -> JSON {
        let typeDefs = self.body.filter { $0 is TypeDefExpression } as! [TypeDefExpression]
        let methods = self.body.filter { $0 is MethodExpression } as! [MethodExpression]
        
        return [
            "@node_type": "API",
            "value": self.name.value,
            "types": typeDefs.map { $0.toJson() },
            "methods": methods.map { $0.toJson() },
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() }
        ]
    }
}

extension ProgramExpression : JSONAwareExpression {
    
    func toJson() -> JSON {
        let apis = (self.apis).map { $0.toJson() }
        
        return [
            "@node_type": "Program",
            "apis": apis,
            "annotations": (self.annotations as! [DebuggableAnnotation]).map { $0.dump() }
        ]
    }
}

extension RootExpression : JSONAwareExpression {
    
    func toJson() -> JSON {
        let prog = self.body[0] as! ProgramExpression
        
        return prog.toJson()
    }
}

