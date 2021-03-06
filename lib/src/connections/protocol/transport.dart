// Copyright (c) 2016, Rik Bellens. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

part of firebase.protocol;

@visibleForTesting
class TransportTester {
  final List<Transport> _activeTransports = [];

  static final _instance = new TransportTester();

  static Future<Null> mockConnectionLost() {
    return _instance._socketCloseAll();
  }

  static Future<Null> mockResetMessage() {
    return _instance._resetAll();
  }

  void addTransport(Transport transport) {
    _activeTransports.add(transport);
    transport.done.then((_) => _activeTransports.remove(transport));
  }

  Future<Null> _socketCloseAll() async {
    await Future.wait(_activeTransports
        .whereType<WebSocketTransport>()
        .map((t) => t._socket.sink.close()));
  }

  Future<Null> _resetAll() async {
    _activeTransports
        .whereType<WebSocketTransport>()
        .forEach((t) => t._onMessage(new ResetMessage(t.host)));
  }
}

abstract class Transport extends Stream<Response> with StreamSink<Request> {
  static const int connecting = 0;
  static const int connected = 1;
  static const int disconnected = 2;
  static const int killed = 2;

  final String host;
  final String namespace;
  final String sessionId;

  Transport(this.host, this.namespace, this.sessionId) {
    TransportTester._instance.addTransport(this);
    _readyState = connecting;
    _connect();
  }

  final Completer<HandshakeInfo> _ready = new Completer();
  final Completer<Null> _done = new Completer();

  Future<HandshakeInfo> get ready => _ready.future;

  @override
  Future<Null> get done => _done.future;

  int _readyState;

  int get readyState => _readyState;

  HandshakeInfo _info;

  HandshakeInfo get info => _info;
  DateTime _infoReceivedTime;

  DateTime get infoReceivedTime => _infoReceivedTime;

  final Map<int, Request> _pendingRequests = {};
  final List<Completer<PongMessage>> _pings = [];

  final StreamController _output = new StreamController(sync: true);
  final StreamController<Response> _input = new StreamController(sync: true);

  Future _connect([String host]);

  Future<void> _reset();

  void _start();

  Future<PongMessage> ping() {
    _pings.add(new Completer());
    _output.add(new PingMessage());
    return _pings.last.future;
  }

  void _onDataMessage(DataMessage v) {
    var request = _pendingRequests.remove(v.reqNum);
    var response = new Response(v, request);
    if (request != null && !request._completer.isCompleted) {
      request._completer.complete(response);
    }
    if (_input.isClosed) return;
    _input.add(response);
  }

  void _onControlMessage(ControlMessage v) {
    if (v is HandshakeMessage) {
      _info = v.info;
      _infoReceivedTime = new DateTime.now();
      _readyState = connected;
      _ready.complete(_info);
      _start();
    } else if (v is ResetMessage) {
      close();
    } else if (v is PongMessage) {
      _pings.removeAt(0).complete(v);
    } else if (v is PingMessage) {
      _output.add(new PongMessage());
    } else if (v is ShutdownMessage) {
      kill();
    }
  }

  void _onMessage(Message v) {
    if (v is DataMessage)
      _onDataMessage(v);
    else
      _onControlMessage(v);
  }

  Request _prepareRequest(Request request) {
    return _pendingRequests[request.message.reqNum] = request;
  }

  @override
  void add(Request event) => _output.add(_prepareRequest(event).message);

  @override
  void addError(dynamic errorEvent, [StackTrace stackTrace]) =>
      _output.addError(errorEvent, stackTrace);

  @override
  Future addStream(Stream<Request> stream) =>
      _output.addStream(stream.map(_prepareRequest));

  @override
  StreamSubscription<Response> listen(void onData(Response event),
      {Function onError, void onDone(), bool cancelOnError}) {
    return _input.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  Future<Null> close() async {
    await _close(disconnected);
    return done;
  }

  Future kill() async {
    await _close(killed);
    return done;
  }

  Future<Null> _close(int state) async {
    if (_readyState >= disconnected) return _done.future;
    _readyState = state;
    await _reset();
    _done.complete();
  }
}

class WebSocketTransport extends Transport {
  static const String protocolVersion = "5";
  static const String versionParam = "v";
  static const String lastSessionParam = "ls";
  static const String transportSessionParam = "s";

  static const int maxFrameSize = 16384;

  WebSocketTransport(String host, String namespace, [String sessionId])
      : super(host, namespace, sessionId);

  StreamSubscription _outputSubscription;

  @override
  void _start() {
    var stream = _output.stream.map(json.encode).expand((v) sync* {
      _logger.fine("send $v");

      var dataSegs = new List.generate(
          (v.length / maxFrameSize).ceil(),
          (i) => v.substring(
              i * maxFrameSize, min((i + 1) * maxFrameSize, v.length)));

      if (dataSegs.length > 1) {
        yield "${dataSegs.length}";
      }
      yield* dataSegs;
    });
    _outputSubscription = stream.listen((v) {
      _socket.sink.add(v);
    });
    _socket.sink.done.then((_) => _outputSubscription.cancel());

    new Stream.periodic(new Duration(seconds: 45))
        .takeWhile((_) => readyState <= Transport.connected)
        .forEach((_) {
      if (!_output.isClosed) _output.add(0);
    });
  }

  WebSocketChannel _socket;

  @override
  Future _connect([String host]) async {
    host ??= this.host;
    var parts = host.split(":");
    host = parts.first;
    var port = parts.length > 1 ? int.parse(parts[1]) : null;
    var url = new Uri(
        scheme: "wss",
        host: host,
        port: port,
        queryParameters: {
          versionParam: protocolVersion,
          "ns": namespace,
          lastSessionParam: sessionId
        },
        path: ".ws");
    _logger.fine("connecting to $url");
    WebSocketChannel socket = _socket = connect(url.toString());
    socket.stream.map((v) {
      _logger.fine("received $v");
      return v;
    }).listen(_handleMessage, onDone: () {
      _logger.fine("WebSocket done: ${socket.closeCode} ${socket.closeReason}");
      close();
    }, onError: (e, tr) {
      _logger.fine("WebSocket error: $e", e, tr);
      close();
    });
  }

  int _totalFrames;
  List<String> _frames;

  void _handleMessage(data) {
    if (_frames != null) {
      _frames.add(data);
      if (_frames.length == this._totalFrames) {
        var fullMess = _frames.join("");
        _frames = null;
        var message =
            new Message.fromJson(json.decode(fullMess) as Map<String, dynamic>);
        _onMessage(message);
      }
    } else {
      if (data.length <= 6) {
        var frameCount = int.parse(data, onError: (_) => null);
        if (frameCount != null) {
          _totalFrames = frameCount;
          _frames = [];
          return;
        }
      }
      var message =
          new Message.fromJson(json.decode(data) as Map<String, dynamic>);
      _onMessage(message);
    }
  }

  @override
  Future<void> _reset() async {
    if (_outputSubscription == null) _output.stream.listen(null);
    await _output.close();
    if (!_input.hasListener) _input.stream.listen(null);
    await _input.close();
    _socket.sink.close();
    _socket = null;
  }
}
