import 'dart:async';
import 'dart:convert';

import 'package:mcp_server/mcp_server.dart';

import 'serve_bundle.dart';

/// booking_server — today's slots at a small place that takes bookings.
///
/// This sample exists to show one bug happening and then not happening. Both
/// tools below do the same thing in plain language: check whether the slot is
/// free, and if it is, take it.
///
/// [_takeUnsafe] does exactly that, and double-books.
/// [_take] does exactly that, and does not.
///
/// The difference is one `await` in the middle. Everything else — the data,
/// the wording, the answer shape — is identical, because the point is that the
/// bug is invisible in the description and only exists in the sequence.
void main(List<String> args) async {
  const config = McpServerConfig(
    name: 'Booking',
    version: '1.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(listChanged: true),
      resources: ResourcesCapability(listChanged: true),
    ),
  );
  final server = McpServer.createServer(config);
  BookingServer(server).register();
  // The screen next door: AppPlayer reads it from here and sends the pages'
  // tool calls back to the tools above.
  registerBundleUi(server, '../booking.mbd');
  final transport = McpServer.createStdioTransport().get();
  server.connect(transport);
  await Completer<void>().future;
}

/// "1 slot", "2 slots". A screen that says "1 slot(s)" is a screen nobody
/// proofread.
String _plural(int n, String one) => "$n $one" + (n == 1 ? "" : "s");

class Slot {
  Slot(this.at);

  final String at;

  /// Who has it. Null means free.
  String? takenBy;

  /// Everybody who has ever been told they got this slot. In a correct
  /// booking system this never has more than one name in it, which is exactly
  /// why it is worth keeping.
  final confirmations = <String>[];
}

class BookingServer {
  BookingServer(this.server);

  final Server server;

  final _slots = <Slot>[
    Slot('09:00'),
    Slot('10:30'),
    Slot('12:00'),
    Slot('14:00'),
  ];

  Slot? _find(String at) {
    final m = _slots.where((s) => s.at == at).toList();
    return m.isEmpty ? null : m.first;
  }

  void register() {
    server.addTool(
      name: 'book.state',
      description: "Today's slots",
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async => _state(),
    );

    // Two people asking for the same slot at the same moment.
    //
    // The overlap is made here, inside the server, and that is on purpose.
    // The first version of this sample sent two tool calls from the client at
    // once and the bug refused to appear — the stdio transport reads one
    // request, runs its handler to completion, and only then reads the next.
    // Over stdio there is no overlap to lose the race in.
    //
    // On an HTTP or SSE transport the overlap arrives by itself and nobody
    // has to arrange it. So this tool arranges what that transport would have
    // handed the server anyway.
    server.addTool(
      name: 'book.stampede',
      description: 'Two people ask for the same slot at the same moment',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'at': {'type': 'string'},
          'first': {'type': 'string'},
          'second': {'type': 'string'},
          'mode': {
            'type': 'string',
            'enum': ['unsafe', 'safe'],
          },
        },
        'required': ['at', 'first', 'second', 'mode'],
      },
      handler: (args) async {
        final at = args['at'] as String;
        final unsafe = args['mode'] == 'unsafe';
        final take = unsafe ? _takeUnsafe : _take;

        // Both started before either is awaited. This is the whole test.
        final a = take(at, args['first'] as String);
        final b = take(at, args['second'] as String);
        final said = await Future.wait([a, b]);

        return _state(
            notice: '${args['mode']}: ${said[0]} | ${said[1]}');
      },
    );

    server.addTool(
      name: 'book.reset',
      description: 'Clear all bookings',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async {
        for (final s in _slots) {
          s.takenBy = null;
          s.confirmations.clear();
        }
        return _state(notice: 'cleared');
      },
    );
  }

  /// The version almost everybody writes first.
  ///
  /// Returns the sentence this person was told, so that a caller can hold two
  /// of them side by side and see that both say yes.
  Future<String> _takeUnsafe(String at, String who) async {
    final slot = _find(at);
    if (slot == null) return 'no slot at $at';

    // 1. Look.
    final free = slot.takenBy == null;

    // 2. Anything at all in here — a database round trip, a payment check, a
    //    log write, a lookup of the customer's name — hands control to
    //    whatever else was in flight. This await is standing in for all of
    //    them. It is not a contrived delay; it is the shape of any real
    //    handler that talks to something.
    await Future<void>.delayed(Duration.zero);

    // 3. Write, using what was true in step 1.
    if (free) {
      slot.takenBy = who;
      slot.confirmations.add(who);
      return 'CONFIRMED $at for $who';
    }
    return '$at is already taken by ${slot.takenBy}';
  }

  /// The same thing, with nothing between the look and the write.
  Future<String> _take(String at, String who) async {
    final slot = _find(at);
    if (slot == null) return 'no slot at $at';

    // Look and write are one step. Whatever else this handler needs to do —
    // charge a card, send a text — happens after the slot is claimed, because
    // the claim is the thing that cannot be shared.
    if (slot.takenBy != null) {
      return '$at is already taken by ${slot.takenBy}';
    }
    slot.takenBy = who;
    slot.confirmations.add(who);

    await Future<void>.delayed(Duration.zero); // the slow part, after the claim
    return 'CONFIRMED $at for $who';
  }

  CallToolResult _state({String notice = ''}) {
    final doubled =
        _slots.where((s) => s.confirmations.length > 1).toList();
    return CallToolResult(content: [
      TextContent(
        text: jsonEncode({
          'rows': [
            for (final s in _slots)
              {
                'at': s.at,
                'who': s.takenBy ?? 'free',
                'taken': s.takenBy != null,
                'double': s.confirmations.length > 1,
                'confirmed': s.confirmations.isEmpty
                    ? ''
                    : 'told yes: ${s.confirmations.join(", ")}',
              },
          ],
          'takenCount': _slots.where((s) => s.takenBy != null).length,
          // The rule a booking desk lives or dies by, printed on the screen
          // that shows the slots. Two people told yes for one slot is not a
          // display problem; it is the thing the server has to prevent.
          'bookingRule': 'One slot, one yes · the seat is taken where the '
              'booking is written, not where it is shown',
          'doubleCount': doubled.length,
          'doubleNote': doubled.isEmpty
              ? 'nobody was told yes twice'
              : '${_plural(doubled.length, "slot")} confirmed to more than one person',
          'notice': notice,
        }),
      )
    ]);
  }
}
