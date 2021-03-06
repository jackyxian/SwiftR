//
//  SwiftR.swift
//  SwiftR
//
//  Created by Adam Hartford on 4/13/15.
//  Copyright (c) 2015 Adam Hartford. All rights reserved.
//

import Foundation
import WebKit

public enum ConnectionType {
    case Hub
    case Persistent
}

public final class SwiftR {
    public class func connect(url: String, connectionType: ConnectionType = .Hub, readyHandler: SignalR -> ()) -> SignalR {
        return SignalR(url: url, connectionType: connectionType, readyHandler: readyHandler)
    }
}

public class SignalR: NSObject, WKScriptMessageHandler {
    var webView: WKWebView!
    var url: String
    var connectionType: ConnectionType
    
    var readyHandler: SignalR -> ()
    var hubs = [String: Hub]()
    
    public var received: (AnyObject? -> ())?
    
    public var queryString: AnyObject? {
        didSet {
            if let qs: AnyObject = queryString {
                if let jsonData = NSJSONSerialization.dataWithJSONObject(qs, options: NSJSONWritingOptions.allZeros, error: nil) {
                    let json = NSString(data: jsonData, encoding: NSUTF8StringEncoding) as! String
                    webView.evaluateJavaScript("connection.qs = \(json)", completionHandler: nil)
                }
            }
        }
    }
    
    init(url: String, connectionType: ConnectionType = .Hub, readyHandler: SignalR -> ()) {
        self.url = url
        self.readyHandler = readyHandler
        self.connectionType = connectionType
        super.init()
        
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, name: "interOp")
        //config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        webView = WKWebView(frame: CGRectZero, configuration: config)
#if COCOAPODS
        let bundle = NSBundle(identifier: "org.cocoapods.SwiftR")!
#else
        let bundle = NSBundle(identifier: "com.adamhartford.SwiftR")!
#endif
        let jqueryURL = bundle.URLForResource("jquery-2.1.3.min", withExtension: "js")!
        let signalRURL = bundle.URLForResource("jquery.signalR-2.2.0.min", withExtension: "js")!
        let jsURL = bundle.URLForResource("SwiftR", withExtension: "js")!
        
        // Loading file:// URLs from NSTemporaryDirectory() works on iOS, not OS X.
        // Workaround on OS X is to include the script directly.

#if os(iOS)
        let temp = NSURL(fileURLWithPath: NSTemporaryDirectory())!
        let jqueryTempURL = temp.URLByAppendingPathComponent("jquery-2.1.3.min.js")
        let signalRTempURL = temp.URLByAppendingPathComponent("jquery.signalR-2.2.0.min.js")
        let jsTempURL = temp.URLByAppendingPathComponent("SwiftR.js")
        
        let fileManager = NSFileManager.defaultManager()
        fileManager.removeItemAtURL(jqueryTempURL, error: nil)
        fileManager.removeItemAtURL(signalRTempURL, error: nil)
        fileManager.removeItemAtURL(jsTempURL, error: nil)
        
        fileManager.copyItemAtURL(jqueryURL, toURL: jqueryTempURL, error: nil)
        fileManager.copyItemAtURL(signalRURL, toURL: signalRTempURL, error: nil)
        fileManager.copyItemAtURL(jsURL, toURL: jsTempURL, error: nil)
    
        let jqueryInclude = "<script src='\(jqueryURL.absoluteString!)'></script>"
        let signalRInclude = "<script src='\(signalRURL.absoluteString!)'></script>"
        let jsInclude = "<script src='\(jsURL.absoluteString!)'></script>"
#else
        var jqueryString = NSString(contentsOfURL: jqueryURL, encoding: NSUTF8StringEncoding, error: nil)!
        var signalRString = NSString(contentsOfURL: signalRURL, encoding: NSUTF8StringEncoding, error: nil)!
        var jsString = NSString(contentsOfURL: jsURL, encoding: NSUTF8StringEncoding, error: nil)!
        
        jqueryString = jqueryString.stringByReplacingOccurrencesOfString("\n", withString: "")
        signalRString = signalRString.stringByReplacingOccurrencesOfString("\n", withString: "")
        jsString = jsString.stringByReplacingOccurrencesOfString("\n", withString: "")
        
        let jqueryInclude = "<script>\(jqueryString)</script>"
        let signalRInclude = "<script>\(signalRString)</script>"
        let jsInclude = "<script>\(jsString)</script>"
#endif
        
        let html = "<!doctype html><html><head></head><body>"
            + "\(jqueryInclude)\(signalRInclude)\(jsInclude))"
            + "</body></html>"
        
        webView.loadHTMLString(html, baseURL: NSBundle.mainBundle().bundleURL)
    }
    
    public func createHubProxy(name: String) -> Hub {
        let hub = Hub(name: name, signalR: self)
        hubs[name.lowercaseString] = hub
        return hub
    }
    
    public func send(data: AnyObject?) {
        var json = "null"
        if let d: AnyObject = data {
            if d is String {
                json = "'\(d)'"
            } else if let jsonData = NSJSONSerialization.dataWithJSONObject(d, options: NSJSONWritingOptions.allZeros, error: nil) {
                json = NSString(data: jsonData, encoding: NSUTF8StringEncoding) as! String
            }
        }
        webView.evaluateJavaScript("connection.send(\(json))", completionHandler: nil)
    }
    
    // MARK: - WKScriptMessageHandler functions
    
    public func userContentController(userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage) {
        if let m = message.body as? String {
            switch m {
            case "ready":
                let isHub = connectionType == .Hub ? "true" : "false"
                webView.evaluateJavaScript("initialize('\(url)',\(isHub))", completionHandler: nil)
                readyHandler(self)
                webView.evaluateJavaScript("start()", completionHandler: nil)
            case "disconnected":
                // TODO
                break
            default:
                break
            }
        } else if let m = message.body as? [String: AnyObject] {
            if let data: AnyObject = m["data"] {
                received?(data)
            } else if let hubName = m["hub"] as? String {
                let method = m["method"] as! String
                let arguments: AnyObject? = m["arguments"]
                let hub = hubs[hubName]
                hub?.handlers[method]?(arguments)
            }
        }
    }
}

// MARK: - Hub

public class Hub {
    let name: String
    
    var handlers: [String: AnyObject? -> ()] = [:]
    
    let signalR: SignalR!
    
    init(name: String, signalR: SignalR) {
        self.name = name
        self.signalR = signalR
    }
    
    public func on(method: String, parameters: [String]? = nil, callback: AnyObject? -> ()) {
        ensureHub()
        handlers[method] = callback
        
        var p = "null"
        if let params = parameters {
            p = "['" + "','".join(params) + "']"
        }
        
        signalR.webView.evaluateJavaScript("addHandler(\(name), '\(method)', \(p))", completionHandler: nil)
    }
    
    public func invoke(method: String, arguments: [AnyObject]?) {
        ensureHub()
        var jsonArguments = [String]()
        
        if let args = arguments {
            for arg in args {
                if arg is String {
                    jsonArguments.append("'\(arg)'")
                } else if let data = NSJSONSerialization.dataWithJSONObject(arg, options: NSJSONWritingOptions.allZeros, error: nil) {
                    jsonArguments.append(NSString(data: data, encoding: NSUTF8StringEncoding) as! String)
                }
            }
        }
        
        let args = ",".join(jsonArguments)
        let js = "\(name).invoke('\(method)', \(args))"
        signalR.webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    func ensureHub() {
        let js = "if (typeof \(name) == 'undefined') \(name) = connection.createHubProxy('\(name)')"
        signalR.webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

extension Hub: Hashable {
    public var hashValue: Int {
        return name.hashValue
    }
}

public func==(lhs: Hub, rhs: Hub) -> Bool {
    return lhs.name == rhs.name
}
