import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bs58/bs58.dart';
import 'package:encrypt/encrypt.dart' as e;
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';
import 'package:path_provider/path_provider.dart' show getDownloadsDirectory, getTemporaryDirectory;
// import 'package:http/http.dart' as http;
import 'package:pointycastle/asymmetric/api.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/screens/chat_profile_screen.dart';
import 'package:prysm/screens/message_composer.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/file_encrypt.dart';
import 'package:prysm/util/message_db_helper.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:prysm/util/rsa_helper.dart';
import 'package:prysm/util/tor_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/client/TorHttpClient.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:prysm/models/contact.dart';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';


class ChatScreen extends StatefulWidget {
    final String userId;
    final String userName;
    final String peerId;
    final String peerName;
    final TorManager torManager;
    final KeyManager keyManager;
    final String? peerPublicKeyPem;
    final int currentTheme;
    final Function() clearChat;
    final Function() reloadUsers;
    
    const ChatScreen({
        required this.userId,
        required this.userName,
        required this.peerId,
        required this.peerName,
        required this.torManager,
        required this.keyManager,
        this.peerPublicKeyPem,
        this.currentTheme = 0,
        required this.clearChat,
        required this.reloadUsers,
        super.key,
    });

    @override
    State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
    var _messages = InMemoryChatController();
    final Map<String, TextMessage> _messageCache = {};
    late final User _user;
    bool _loading = false;
    bool _hasMore = true;
    int? _oldestTimestamp;
    String? _oldestMessageId;
    int? _newestTimestamp;

    RSAPublicKey? _peerPublicKey;

    String _peerName = '';
    int _currentTheme = 0;
    int _lastMessageCount = 0;

    Set<String> selectedMessageIds = {};

    Message? _replyToMessage;
    
    Map<String, double> _dragOffsets = {}; // messageId -> offset

    Key _chatKey = UniqueKey();
    final AutoScrollController _scrollController = AutoScrollController();
    Timer? _debounceTimer;
    Timer? _retryTimer;

    void _scrollListener() {
        // LOAD WHEN NEAR TOP (not bottom)
        if (_scrollController.position.pixels <= 50 && !_loading && _hasMore) {
            if (_debounceTimer?.isActive ?? false) return;
            _debounceTimer = Timer(const Duration(milliseconds: 600), () async {
                await _loadMoreMessages();
            });
        }
    }


    @override
    void initState() {
        super.initState();
        _currentTheme = widget.currentTheme;
        _peerName = widget.peerName;
        _user = User(id: widget.userId);
        _fetchPeerPublicKey().then((_) {
            _loadInitialMessages();
            _startPolling();
        });
        _scrollController.addListener(_scrollListener);
        startOutgoingSender();
    }

    @override
    void dispose() {
        _retryTimer?.cancel();
        _debounceTimer?.cancel();
        _scrollController.removeListener(_scrollListener);
        super.dispose();
    }

    void resetChatState() {
        _messages = InMemoryChatController();
        _replyToMessage = null;
        _messageCache.clear();
        _oldestTimestamp = null;
        _oldestMessageId = null;
        _newestTimestamp = null;
        _hasMore = true;
        _loading = false;
        // (Reset any other relevant per-chat state here!)
    }

  @override
    void didUpdateWidget(covariant ChatScreen oldWidget) {
        super.didUpdateWidget(oldWidget);
        if (oldWidget.peerId != widget.peerId) {
            // Chat peer changed!
            print("CHANGED CHAT: ${oldWidget.peerId} -> ${widget.peerId}");
            setState(() {
                resetChatState();
                _chatKey = UniqueKey();
            });
            _fetchPeerPublicKey().then((_) => _loadInitialMessages());
        }
        // For theme/name change, update without full reset
        if (oldWidget.currentTheme != widget.currentTheme) {
            setState(() {
                _currentTheme = widget.currentTheme;
            });
        }
        if (oldWidget.peerName != widget.peerName) {
            setState(() {
                _peerName = widget.peerName;
            });
        }
    }

    void startOutgoingSender() async {
        _retryTimer = Timer.periodic(Duration(seconds: 15), (_) async {
            final messages = await PendingMessageDbHelper.getPendingMessages();
            for (var msg in messages) {
                bool res = await _sendOverTor(msg['id'], msg['message'], msg['type'], replyToId: msg['replyTo']);
                if (res) {
                    await PendingMessageDbHelper.removeMessage(msg['id']);
                    var messageIdx = _messages.messages.indexWhere((m) => m.id == msg['id']);
                    if (messageIdx != -1 && mounted) {
                        final updatedMessage = _messages.messages[messageIdx].copyWith(seenAt: DateTime.now());
                    }
                    await MessagesDb.setAsRead(msg['id']); // update the message as read
                } else {
                    // Skip
                    //
                    print("DEBUG: Send retry failed for message ID: ${msg['id']}.");
                }
            }
        });
    }

    Future<List<Message>> decryptMessagesDeferred(List<Map<String, dynamic>> rawMessages, KeyManager keyManager) async {
        List<Message> messages = [];

        for (var msg in rawMessages) {
            if (_messageCache.containsKey(msg['id'])) {
                messages.add(_messageCache[msg['id']]!);
                continue;
            }
            try {
                
                if (msg['type'] == 'text') {
                    print(msg['readAt']);
                    messages.add(TextMessage(
                        authorId: User(id: msg['senderId']).id,
                        createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                        id: msg['id'],
                        replyToMessageId: msg['replyTo'],
                        seenAt: msg['readAt'] != null
                            ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
                            : null,
                        text: keyManager.decryptMessage(msg['message']),
                    ));
                } 
                else if (msg['type'] == 'file') {
                    messages.add(FileMessage(
                        id: msg['id'],
                        authorId: User(id: msg['senderId']).id,
                        createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                        replyToMessageId: msg['replyTo'],
                        name: msg['fileName'] ?? "Unknown",
                        size: msg['fileSize'] ?? 0,
                        seenAt: msg['readAt'] != null
                            ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
                            : null,
                        source: msg['message'], // Not ready yet
                    ));
                } 
                else if (msg['type'] == "image") {
                    messages.add(ImageMessage(
                        id: msg['id'],
                        authorId: User(id: msg['senderId']).id,
                        createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                        replyToMessageId: msg['replyTo'],
                        size: msg['fileSize'] ?? 0,
                        seenAt: msg['readAt'] != null
                            ? DateTime.fromMillisecondsSinceEpoch(msg['readAt'] as int)
                            : null,
                        source: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAfQAAAH0CAIAAABEtEjdAAAACXBIWXMAAA7EAAAOxAGVKw4bAAAEtWlUWHRYTUw6Y29tLmFkb2JlLnhtcAAAAAAAPD94cGFja2V0IGJlZ2luPSfvu78nIGlkPSdXNU0wTXBDZWhpSHpyZVN6TlRjemtjOWQnPz4KPHg6eG1wbWV0YSB4bWxuczp4PSdhZG9iZTpuczptZXRhLyc+CjxyZGY6UkRGIHhtbG5zOnJkZj0naHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyc+CgogPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9JycKICB4bWxuczpBdHRyaWI9J2h0dHA6Ly9ucy5hdHRyaWJ1dGlvbi5jb20vYWRzLzEuMC8nPgogIDxBdHRyaWI6QWRzPgogICA8cmRmOlNlcT4KICAgIDxyZGY6bGkgcmRmOnBhcnNlVHlwZT0nUmVzb3VyY2UnPgogICAgIDxBdHRyaWI6Q3JlYXRlZD4yMDI1LTEwLTI3PC9BdHRyaWI6Q3JlYXRlZD4KICAgICA8QXR0cmliOkV4dElkPjc1OWE3MjEyLWEwNGYtNDM3OC1iZTUwLTc1MjNmMGM1MzAwNDwvQXR0cmliOkV4dElkPgogICAgIDxBdHRyaWI6RmJJZD41MjUyNjU5MTQxNzk1ODA8L0F0dHJpYjpGYklkPgogICAgIDxBdHRyaWI6VG91Y2hUeXBlPjI8L0F0dHJpYjpUb3VjaFR5cGU+CiAgICA8L3JkZjpsaT4KICAgPC9yZGY6U2VxPgogIDwvQXR0cmliOkFkcz4KIDwvcmRmOkRlc2NyaXB0aW9uPgoKIDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PScnCiAgeG1sbnM6ZGM9J2h0dHA6Ly9wdXJsLm9yZy9kYy9lbGVtZW50cy8xLjEvJz4KICA8ZGM6dGl0bGU+CiAgIDxyZGY6QWx0PgogICAgPHJkZjpsaSB4bWw6bGFuZz0neC1kZWZhdWx0Jz5VbnRpdGxlZCBkZXNpZ24gLSAxPC9yZGY6bGk+CiAgIDwvcmRmOkFsdD4KICA8L2RjOnRpdGxlPgogPC9yZGY6RGVzY3JpcHRpb24+CgogPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9JycKICB4bWxuczpwZGY9J2h0dHA6Ly9ucy5hZG9iZS5jb20vcGRmLzEuMy8nPgogIDxwZGY6QXV0aG9yPnhtcmV1cjwvcGRmOkF1dGhvcj4KIDwvcmRmOkRlc2NyaXB0aW9uPgoKIDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PScnCiAgeG1sbnM6eG1wPSdodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvJz4KICA8eG1wOkNyZWF0b3JUb29sPkNhbnZhIChSZW5kZXJlcikgZG9jPURBRzItQ0M3QmowIHVzZXI9VUFHMi1QM1g2Z0kgYnJhbmQ9QkFHMi1EUGF2ancgdGVtcGxhdGU9PC94bXA6Q3JlYXRvclRvb2w+CiA8L3JkZjpEZXNjcmlwdGlvbj4KPC9yZGY6UkRGPgo8L3g6eG1wbWV0YT4KPD94cGFja2V0IGVuZD0ncic/Pu7JWa4AABtuSURBVHic7N3tT9XlH8Bx4KDcmFqCWqYrNK3UZE3LnNWcy62Wuu5cLtfWg3xgd1vrX+ivaD3pScullqapK6dNwVJDRWeSBmrRWSogeMPtgd8DNsbOORAqyc8Pr9czru/Fl4vDfPPlOt9zzK2pqckBIJa8kV4AAMNP3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdICBxBwhI3AECEneAgMQdIKD8kV4ADLPm5ubLly+nDRYWFj744IMDfUpTU9Px48ebmpoKCwtnzpw5Z86c3Nzc/3iZ8N/KrampGek1wHCqrKzcsWNH2uD06dM3bNiQdX5VVdXWrVu7urr6RsrKyt5+++2CgoL/cJXwH7MtM/Jas+nfGv47Fy9e/Oabb9Ie7bq6uu+++26klgTDwrbMCGtvb//0008zx1esWLFs2bI7vpxRp6qqqru7O3O8urp61apVLt65e7lyZ1S7cuVK1vFUKtXS0nKHFwPDSNwZ1YqLiwc6NG7cuDu5Ehhe4s6oNm/evKzjM2fOHKT78P9P3BnVZs2atWTJkrTBCRMmvPLKKyOyHhgunlBltFu5cmVZWVlVVVXvfe5lZWVLly69Gy/bd+7cefXq1bKyspkzZ5aUlIz0chhh4g458+bNG2h/5i5y7Nixa9euHT9+PCcnZ8KECXPmzHn11VdHelGMGNsyEEFDQ8O1a9f6PmxpaWloaBjB9TDiXLmPUqlUqrGxsbW1tbOzc+zYscXFxffdd19e3rD9su/o6Ghqampra0ulUgUFBYWFhffee28ikbj9M6dSqYaGhhs3buTm5o4fP378+PFjxoy5/dMOu46OjsuXL7e1tY0ZM6a4uHjixIn5+bf7z+3GjRtNTU3t7e25ubkFBQWTJk0qLCzsPXT06NG0ybNnz77NL8ddTdxHl/r6+hMnTvz++++XLl1Ke/FOfn7+1KlT58yZU15ePnny5Fs4eXd39+nTp3/77be6urorV6709PT0P5pIJKZMmTJr1qynn376FnaE29vbf/311xMnTtTX16dSqb7xvLy8hx9+eP78+QsXLry1em7atOnq1atpg88999wjjzySOfns2bP79+9PG5w7d+7ixYv71nno0KHq6upkMtn/EcjPz58xY8aCBQsWLVp0U79Ee3p6ampqjh07Vltbe/369bSjkyZNeuyxx8rLy3/++ef+40VFRc8888zQvwrxiPto8ddff+3atauurm6gCV1dXfX19fX19fv27Xv00Udfeuml0tLSIZ68s7Pz4MGDFRUV/XcG0qRSqWQymUwmKyoqFi5cuHLlyqFfcR85cmT37t03btzIPNTd3V1bW1tbW3vgwIG1a9cO8u5gAzl//nxjY2PaYHl5edbJLS0tZ8+eTRvse6DOnDmzZcuWrK9+6urqqqurq6urO3DgwLp166ZOnTqUtZ07d27btm3//PPPQBMaGxsrKysrKyv7DyYSiddff93La0c5cY+vp6fnhx9+2L9/f9bX2Wedf/r06bNnz7744ouZtwlmOnPmzNatW5uamoa+niNHjiSTyfXr1/9r33t6erZs2VJVVfWvp21sbPz888/feeedIS5j2FVXV3/99df/+iA3NDR89tln69evv//++wefWVlZuXPnziH+1PqMGzduzZo19mTwhGpwPT09X3311U8//XSzjejq6tq+ffvOnTsHn7Z3794vvvhi6GXvU19f/+233/7rtK1btw6l7L06Ojq+/PLL06dP3+xibt/ff/+9efPmIT7IbW1tmzZtGnxyVVXVjh07bvanNmnSpI8//ljZyRH38Hbs2HHy5Mlb/vQDBw6k/cnf3+7du3/88ce0vfWhO378eDKZHGRCdXX14cOHb+qc165d++OPP25tPbcsmUxu3rz5pt7IM5lMnjhxYqCjV69eHehtKROJRElJSUlJSdaN++bm5gsXLgx9GQRmWyaympqagwcPDjKhsLCwqKiotbW1ra1toDm7du2aNWtW1j3iQTZVSktLH3jggXvuuScnJ6elpeXcuXOZTwb29PQcPnx49erVWc/Q2dn5/fffD7L4RCLR+/Yv169f7/8U6513/vz5/h/m5uYWFxcXFha2trZmfZ6g1+HDhwfa2d+/f39HR0faYCKRWLFixeLFi8eOHZuTk9Pe3l5RUbF3797+V/epVGrjxo2ffPKJN8ZB3MPq7u7evn171kNFRUXLli1bsGDBhAkTekcaGhqOHj1aUVGR2ZRUKrVt27b169dnnmfZsmWnTp3qf/WdSCSeeuqpJUuWpD0Z29XVtXHjxlOnTqWdoba2dqD1Hzp0KPMmll7Tpk1bvnz57Nmze2+P6ezsrKmp2bNnz8WLFwc6251RXFzc+8COHz++d+Ty5ct79uyprq7OnHzhwoWurq6sd/hk/WNr9erVixYt6vuwoKBg+fLlRUVFaT/l9vb2ffv2vfzyy7f1nXD3sy0T1smTJzNvAsnJySkpKfnoo4+effbZvrL3Dr7wwgsbNmzoq1J/586d+/PPPzPH8/LyXnvttb671x966KH3339/1apVmbfZ5OfnZ321ZENDw0C7OkeOHMk6Xl5e/t577z3++ON9WRwzZsz8+fM/+OCDuXPnZv2UO6O0tPTDDz9cunRp/8ewtLT0zTfffOKJJzLn994+lDne3Nzc3NycNjhx4sSFCxdmTl68eHHmjyzzlyijkLiHlXW3Oi8vb926df2z3t+UKVPWrFmT9dAvv/ySdXzatGnPP/98Tk7Ok08++e677w5yh1/vTkXaYHd3d9YdoUuXLmW9DJ88efIbb7yR9T84TSQSa9euHfrtm8MrPz//rbfeGuiBXb58edbxrO8mn/XZ6RkzZmT9rvPy8qZPn5552sxNMEab/wEAAP//7d3rT1v1H8Dxll5WilAGBEbLbRDFC7CxCKIy3CaXmRiJC8apMy7qXPCpj/dP+MgHJjMuc1G3eSFOcUqISGC3MHcjG5PbYCAMhCqUttD+HjQ/Qs75tnTCGP3wfj3bWVsq+/3ePf2e7/d7iLtMXq9XMxAcsm3btsgzrAsKCpSLd27duhXuFHv37t2vvfZaQ0ND5LU5oeWa+uP6gSCDwRBuPv6ePXsi/BSTyVRXVxfhPTw4RUVFEX6x6enpykFw5S/E7/frD+o/FxfFx8frD0ZYcIANgrjLNDg4qLzGWFJSsuxzlY+ZmZkJN6JtMpm2b98e+TUHBgaOHTu27I9edPfuXf1Bi8XyxBNPRH7i448//lCuJS77i1WOdyk/2JSLjyJc8fZ4PPqDytN8bChcUJVJGWKj0Zibm7vsc3NycsK9ZpTrKkPcbvfw8PCdO3du3boVecqjnvJqQUZGxrKLnuLi4rKzs9d+qrt+bEQjNMVFQ/llSDmyNDQ0FAwG9ckOBAJDQ0P6xys/S7ChEHeZlOO2DocjmiXpaWlpJpNJf+KvDO5SgUCgr6+vt7d3cHBwZGREeUYZJeUK/ih3vMnIyFjjuFut1lX8umC32zMyMjRbDkxNTXV1de3YsUPzYOWcorS0NOVYDTYU4i6T8lt8lP+HD+04qJ+g7fV6wz1lenq6vb29q6srwrTu+6Icr4gw7rzU2nctyjcWvbKyMv001u+++87r9ZaVlYWmCfl8vo6Ojl9++UX/9HDT57GhEHeZlBflot+oy2q1Rhn3YDDY1tbW0tKi/IlLJSQkeL3eKJdxKh+mHNnQW/sNs1a+l69GeXn5+fPnNWNroQ0hmpubk5OTDQbD5OSk8rKK3W5/7rnnVvf9IBZxQVUm5c7p0S/jVLZV+dlw+vTp5ubmCGU3Go2ZmZm1tbUfffSR0+mM8g0o3/9KPhhii8lkOnDgQGh9r4bf7x8fHx8fH1f+a8bFxTU0NKz6NwnEIs7cZbrfGRcaypN0/YlzZ2enclevuLi4goKC/Pz8rKwsp9P5H1qj/CBRjtXoRf+fuZ6lpqYePnz4iy++iP5atNls3rdvX2Fh4QN9Y4gVxF0m5WqaqampQCCw7J0ipqenlWfimtdcWFj49ddf9Q9zuVyvv/76Cm/QnJCQoL9L3LJXdEPu3bu3kh+9fqSkpHz44YefffZZNFuh5eTkvPLKK5mZmWvwxhATiLtMyoklCwsLo6Ojy46NDA8PK4+np6cv/ePt27f14/JWq/Wdd94JN3UkwiVZjeTkZP3uhqOjo8rpgBrh3n/MuXbtWkdHh3Ix2qKkpKSCgoLS0tKCgoI1e2OICcRdpuzsbOXxa9euLRt35a5VFotFc1aoHC7Iz8+PMClQOcFRSTmhfmZmZmBgIC8vL8IT7969K+DMfX5+/sSJE0sndNpstrq6OqfTGQgE/H7/4j1UmfKIcIi7TA6HIz09Xb+U6cKFCzt37oxQhImJievXr+uP5+XlacbBlbMe7XZ7uFe+r5nv4RZb/f7775Hj3tLSEuWPWM9++uknzVT9Xbt2lZeXr8qLT0xM9Pb2ejweh8Px2GOPRfgfw8LCQk9Pz/j4uMVicblc4c4YQjwez82bN91ud3x8fEFBQUpKyqq8W/xnxF2s7du3//zzz5qDs7Ozp06devPNN5Uj7z6f7+TJk8rZJqWlpZojyldQ7oQVEu6mH8qbDeXk5IQ2mtcc7+7uvnjx4tKdbzU/oru7O9wbiBWBQODSpUuag9FPY41gYWEhdGerxZWxFotl7969yltp9/X1ffXVV0u/bOXk5Ozfv9/hcOgf3NHRsXTSlNFo3LFjR319vXLWE9YGcV+nxsfH77dTKSkpS0czysvLW1tb9TNMuru7jx49+vLLL2uGPgYGBpqampSDLcnJyfpNa5UT9fr7+8fGxjSj8waD4cqVK11dXcq3PTw8vHnzZs1Bk8lUXFx8/vx5/eO//fbbe/fu7dq1a+kkHI/Hc/bs2XBbV8aWf//9V/+v1traunnz5oKCgpXMqT9z5ozmY8Pv9zc1NTkcDs2mPVNTU8eOHdNcIxkcHDx+/HhjY6Pmssf169c1S66CweClS5c2bdrEtvIPEXFfpy5fvnz58uX7ekp5eXl9ff3iH+Pj43fv3t3c3Kx/ZG9v78cff5yenp6enm6z2WZnZ0dGRiLcB/Wll17Sn6crx+4DgcDRo0dra2tLSkpCZ21TU1Pt7e2dnZ3hNpU8derUjRs3PB5PcXHx0uX1lZWVFy9e1J/Xh5ZNdXR0ZGdnh5bzTE1NhdsoLRbZ7Xaj0aj5df3zzz+ff/650Wi02WwWi8VisZjNZsv/2e32Rx55JCMjIzc3N9w8pbm5uXBb5Le1tWni3tnZqbz6PTw83Nvbq7l4+9tvvylf9sKFC9XV1Wu/pgwhxF2yysrK7u7ucDfVHBsbi+bWRUVFRUVFRfrjeXl5drtdP/LudrtPnjx5+vTpxMTE+fn5ZTcW9/l8f/zxh8FgSE1NXRr31NTUsrKycCfj8/Pz4bYFjnVmszk3N7e/v1//V8Fg0OPxRL504XK5Kisr9btUjo2NhVveNTo6qjkSYXL9yMiIJu76p4f4/f6JiYnoV65hdbFCVbK4uLgDBw6sZMp5dnZ2Q0NDuBevrKwM98RAIDA9Pb207BaLpbGxMcIWAvq5NHv37r3fN5+bmytg8X1dXd1/Hn4ZHh7+8ssvjx8/rvkqE2H4W/9XD+7BWDPEXbiEhITDhw8vuyGtUmFh4bvvvhvhUl5VVVX006tramqysrKU94oL0e9uaLVaDx48GO72RnqJiYlvvPGGfgQ/5uTk5Lz11lsRph4t68aNG19//fXSIxkZGeEmxugnIEWYkqT/q3BTmxISEqLcyBMPAnGXL9T36urqKDfeMhgM8fHx9fX1b7/9duSnGI3G/fv3K+/cpFFVVfX8888bDIaamppwqyiVt8NOSUlpbGyMZht6l8v1wQcfiNnH3Ol0RnNnlQiuXr16+/btxT+azebq6mr9w6xWq/54eXm58jtTaWmp/p+vurpa+T2jrq5u2eXQeHAYc98Q4uLidu/e/cwzz3R2dl69ejXcULvRaHS5XNu2bXv66aej/CSw2+0HDx48d+5cW1ubch6k0+msrq5e3PBk06ZNhw4dam1t7erqWlrzxMRE5ci+wWBISko6dOjQlStX2tvblatPExISnn322aqqKhmDAHfu3Dl79mxvb2+4S9DRO3fu3NKP3oqKCrPZ3NLSsngDbqfTWV9fr18yZrPZ3n///e+///7mzZuha9pWq7WioqKmpkb/U1wu13vvvdfU1LR4/6ykpKTa2lr99FmsJePNmzcf9nvAWnO73aGVnHNzc/Pz8xaLJT4+Pi0tzeVy/eebTgSDwZGRkaGhIbfb7ff7rVZrcnJybm5uhDtWu93umZkZs9mclJQU5ZyKv//+e3BwcHJy0uv1mkymxMREp9OZlZUl5gyxs7Pzhx9+WDpHyGg0FhYWlpSUOByOhYUFr9fr8/l8Pp/f7/f5fF6vd3p6uq+vT/m9x2azHTlyRHMwGAxOTEx4PJ6kpCTlpPWlPB7P5OSk0WhMT09f9jKA2+2enp622WxpaWnc5++hI+7AetHf3//pp59qTtj37Nnz4osvRn7iwsLCiRMnlAsjjhw5wg7AG5OQ8x1AgLa2Nv1QTDSTf0wmU7gPgJXc7BAxjbgD64V+RYLJZIryvFu5YNjwMO5LhXWCuAPrhX6RUWjrrmieq7wnuN1uX8l8SsQ04g6sF8oZ/d98882yO9T39PScOXNGf5xN3jcypkIC68XWrVv1m9G73e5PPvmksLCwsLBwy5YtDofDarUGg0Gfzzc1NTUyMnLjxo1wt2parV2CEYuIO7BeVFRUXLp0Sb9XWiAQ6O7uvt9dQp966qn8/PzVe3eIMQzLAOvFli1bamtrV+WlMjMz9+3btyovhRjFmTuwjuzcudNsNv/4448r2cG4uLj41VdfZZ7MBsciJmDdGRsba21tvXr1qvI2VRFs3br1hRdeePTRRx/QG0MMIe7AOjU7O9vT0/Pnn3/+9ddfk5OTypvWmkwmh8ORmZmZk5Pz5JNPcudSLCLuQGzw+Xxzc3N+v9/v9xuNRrPZbLPZQrdtethvDesRY+5AbLBardFv2gwwWwYABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BAxB0ABCLuACAQcQcAgYg7AAhE3AFAIOIOAAIRdwAQiLgDgEDEHQAEIu4AIBBxBwCBiDsACETcAUAg4g4AAhF3ABCIuAOAQMQdAAQi7gAgEHEHAIGIOwAIRNwBQCDiDgACEXcAEIi4A4BA/wMZci3Hm/1TdQAAAABJRU5ErkJggg==", // Not ready yet
                    ));
                    
                    decryptFileInBackground(msg, keyManager).then((decryptedBytes) {
                        final index = messages.indexWhere((m) => m.id == msg['id']);
                        var oldMessage;

                        if (index != -1) {
                            if (msg['type'] == "file") {
                                oldMessage = messages[index] as FileMessage;
                            } else {
                                oldMessage = messages[index] as ImageMessage;
                            }
                            final newMessage = oldMessage.copyWith(
                                source: base64Encode(decryptedBytes),
                                size: decryptedBytes.length,
                            );
                            setState(() {
                                messages[index] = newMessage;
                            });
                        }
                    });
                }
            } catch (e) {
                print(e);
                messages.add(TextMessage(
                    authorId: User(id: msg['senderId']).id,
                    createdAt: DateTime.fromMillisecondsSinceEpoch(msg['timestamp']),
                    id: msg['id'],
                    replyToMessageId: msg['replyTo'],
                    text: '🔒 Unable to decrypt message',
                ));
            }
        }
        return messages;
    }

    Future<Uint8List> decryptFileInBackground(Map<String, dynamic> msg, KeyManager keyManager) async {
        final hybrid = jsonDecode(msg['message']);
        final rsaEncryptedAesKey = hybrid['aes_key'];
        final iv = e.IV.fromBase64(hybrid['iv']);
        final encryptedData = base64Decode(hybrid['data']);
        final aesKeyBytes = keyManager.decryptMyMessageBytes(rsaEncryptedAesKey);
        final aesKey = e.Key(Uint8List.fromList(aesKeyBytes));
        final decryptedBytes = AESHelper.decryptBytes(encryptedData, aesKey, iv);
        return decryptedBytes;
    }

    String decodeBase58ToOnion(String base58String) {
        final bytes = base58.decode(base58String);
        final onion = utf8.decode(bytes);
        return '$onion.onion';
    }

    Future<String?> _getPeerPublicKeyPemFromDb(String peerId) async {
        final users = await DBHelper.getUsers(); // Or a specialized query for one user
        try {
            final user = users.firstWhere((u) => u['id'] == peerId);
            return user['publicKeyPem'] as String?;
        } catch (e) {
            return null; // Not found
        }
    }

    Future<bool> _fetchPeerPublicKey() async {
        if (widget.peerPublicKeyPem != null) {
            _peerPublicKey =
                widget.keyManager.importPeerPublicKey(widget.peerPublicKeyPem!);
            return true;
        }

        final cachedPem = await _getPeerPublicKeyPemFromDb(widget.peerId);
        if (cachedPem != null && cachedPem.isNotEmpty) {
            _peerPublicKey = widget.keyManager.importPeerPublicKey(cachedPem);
            return true;
        }

        final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);

        try {
            final peerOnion = widget.peerId;
            final uri = Uri.parse("http://$peerOnion:80/public");
            final response = await torClient.get(uri, {});
            final publicKeyPem = await response.transform(utf8.decoder).join();

            setState(() {
                _peerPublicKey =
                    widget.keyManager.importPeerPublicKey(publicKeyPem);
            });
        } catch (e) {
            print("Failed to fetch peer public key: $e");
            return false;
        } finally {
            torClient.close();
        }

        return true;
    }

    Future<void> _loadInitialMessages() async {
        () async {
            setState(() {
               _messages = InMemoryChatController();  
            });
        };
        await _loadMoreMessages();
    }

    Future<void> _loadMoreMessages() async {
        if (_loading || !_hasMore) return;
            _loading = true;

        final batch = await MessagesDb.getMessagesBetweenBatchWithId(
            widget.userId,
            widget.peerId,
            limit: 20,
            beforeTimestamp: _oldestTimestamp,
            beforeId: _oldestMessageId,
        );

        /* print("old_TIME $_oldestTimestamp");
        print("new_TIME $_newestTimestamp");
        print("loading: $_loading");
        print("hasmore: $_hasMore");*/
        print("${batch.length}"); 
        //print("$batch"); 
        if (!mounted) return;

        if (batch.length < 20) {
            print("hasMore = false");
            _hasMore = false;
            _loading = false;
            if (batch.isEmpty) {
                return;
            }
        }

        final modifiableList = List.of(batch);
        modifiableList.sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));

        final newMessages = await decryptMessagesDeferred(modifiableList, widget.keyManager);
    
        print("Loaded ${newMessages.length} more messages.");
        setState(() {
            _messages.insertAllMessages(newMessages, index: 0);
            _oldestTimestamp = batch.last['timestamp'];
            _oldestMessageId = batch.last['id']; // track last loaded message id
            _loading = false;
        });
    }

    void _startPolling() {
        Future.doWhile(() async {
            await Future.delayed(const Duration(seconds: 2));

            _loadNewMessages();
            return true;
        });
    }

  Future<void> _loadNewMessages() async {
        final batch = await MessagesDb.getMessagesBetweenBatch(
            widget.userId, widget.peerId,
            limit: 20,
            beforeTimestamp: null,
        );

        final newMessagesRaw = batch.where((msg) => _newestTimestamp == null || msg['timestamp'] > _newestTimestamp).toList();

        if (newMessagesRaw.isEmpty) return;

        final existingIds = _messages.messages.map((m) => m.id).toSet();
        final filteredRaw = newMessagesRaw.where((msg) => !existingIds.contains(msg['id'])).toList();

        if (filteredRaw.isEmpty) return;

        // Decrypt the filtered messages outside setState and main UI flow
        final decryptedMessages = await decryptMessagesDeferred(filteredRaw, widget.keyManager);

        if (!mounted) return; 
        setState(() {
        // Insert all decrypted messages at once at the end of the list
            for (final msg in decryptedMessages) {
                _messages.insertMessage(msg, index: _messages.messages.length);
            }
        });

        _newestTimestamp = newMessagesRaw.first['timestamp'];
    }



    void _handleSendText(String text) async {

        if (!mounted) return;

        if (_peerPublicKey == null) {
    
            bool k = await _fetchPeerPublicKey();
        
            if (!mounted) return;

            if (k) {
                _loadInitialMessages();
                _startPolling();
            } else {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Couldn\'t send message: Peer public key not available.'),
                        duration: Duration(seconds: 3),
                    ),
                );
                return;
            }
        }

        var replyToId = _replyToMessage?.id;

        final encryptedForPeer =
            widget.keyManager.encryptForPeer(text, _peerPublicKey!);
        final encryptedForSelf =
            widget.keyManager.encryptForSelf(text);

        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final messageId = Uuid().v4();

        print("Sending message ID: $messageId, replyTo: {$replyToId}");
        
        // Store in DB
        await MessagesDb.insertMessage({
            'id': messageId,
            'senderId': widget.userId,
            'receiverId': widget.peerId,
            'message': encryptedForSelf,
            'type': 'text',
            'status': 'sent',
            'timestamp': timestamp,
            'replyTo': replyToId,
        });

        // Show decrypted instantly
        setState(() {
            _messages.insertMessage( 
                TextMessage(
                    authorId: _user.id,
                    createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
                    id: messageId,
                    text: text,
                    sentAt: DateTime.now(),
                    replyToMessageId: replyToId,
                ),
                index: _messages.messages.length,
            );
            _replyToMessage = null;
        });

        // Send encrypted to peer
        bool res = await _sendOverTor(messageId, encryptedForPeer, "text", replyToId: replyToId);
        if (res) {
            print('Sent: $text');

            await MessagesDb.updateMessageStatus(messageId, 'received');
            await MessagesDb.setAsRead(messageId);

            final message = _messages.messages.firstWhere((m) => m.id == messageId);
            if (message != -1 && mounted) {
                
                _messages.updateMessage(message, message.copyWith(seenAt: DateTime.now()));
            }
        }

        if (res == false) {
            await PendingMessageDbHelper.insertPendingMessage({
                'id': messageId,
                'senderId': widget.userId,
                'receiverId': widget.peerId,
                'message': encryptedForPeer,
                'type': 'text',
                'timestamp': timestamp,
                'replyTo': replyToId,
            });
        }

    }

  Future<void> _handleSendImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery, requestFullMetadata: true);
    if (pickedFile == null) return;

    final bytes = await pickedFile.readAsBytes();
    _sendFile(bytes, pickedFile.name, "image");
  }

  Future<void> _handleSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;

    _sendFile(file.bytes!, file.name, "file");
  }

  Future<void> _sendFile(Uint8List bytes, String fileName, String type) async {

    if (_peerPublicKey == null) {
    
      bool k = await _fetchPeerPublicKey();

      if (k) {
        _loadInitialMessages();
        _startPolling();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn\'t send message: Peer public key not available.'),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
    }


    var replyToId = _replyToMessage?.id;
    // Generate AES key + iv
    final aesKey = AESHelper.generateAESKey();
    final iv = AESHelper.generateIV();
    print('Generated key and iv');
    // Encrypt file with AES
    final aesEncryptedBytes = AESHelper.encryptBytes(bytes, aesKey, iv);
    print('Encrypted file with AES');
    // Encrypt AES key with peer's RSA key
    final rsaEncryptedAesKey = RSAHelper.encryptBytesWithPublicKey(aesKey.bytes, _peerPublicKey!);
    print('Encrypted AES with RSA ');
    final payload = jsonEncode({
      "aes_key": rsaEncryptedAesKey,
      "iv": iv.base64,
      "data": base64Encode(aesEncryptedBytes)
    });

    print('made payload');
    final selfEncryptedKey = RSAHelper.encryptBytesWithPublicKey(aesKey.bytes, widget.keyManager.publicKey);
    final selfPayload = jsonEncode({
      "aes_key": selfEncryptedKey,
      "iv": iv.base64,
      "data": base64Encode(aesEncryptedBytes),
    });

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageId = Uuid().v4();

    // Store locally
    await MessagesDb.insertMessage({
      'id': messageId,
      'senderId': widget.userId,
      'receiverId': widget.peerId,
      'message': selfPayload,
      'type': type,
      'fileName': fileName,
      'fileSize': bytes.length,
      'timestamp': timestamp,
      'replyTo': replyToId,
    });

    // Show immediately in chat
    setState(() {
      if (type == "file") {
        _messages.insertMessage(
          FileMessage(
            authorId: _user.id,
            createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
            id: messageId,
            name: fileName,
            size: bytes.length,
            replyToMessageId: replyToId,
            source: selfPayload,
          ),
          index: _messages.messages.length,
        );
      } else if (type == "image") {
        _messages.insertMessage(
          ImageMessage(
            authorId: _user.id,
            createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
            id: messageId,
            size: bytes.length,
            replyToMessageId: replyToId,
            source: "data:image/png;base64,${base64Encode(bytes.toList())}",
          ),
          index: _messages.messages.length,
        );
      }
    });
    print('~$payload~');
    final success = await _sendOverTor(messageId, payload, type, fileName: fileName, fileSize: bytes.length);
    print('Failed to send message: $success');
    if (!success) {
      await PendingMessageDbHelper.insertPendingMessage({
        "id": messageId,
        "senderId": widget.userId,
        "receiverId": widget.peerId,
        "message": payload,
        "type": type,
        "fileName": fileName,
        "fileSize": bytes.length,
        "timestamp": timestamp,
        'replyTo': replyToId,
      });
    }
  }

  Future<bool> _sendOverTor(
    String id,
    String encrypted,
    String type, {
    String? replyToId,
    String? fileName,
    int? fileSize,
  }) async {
    final torClient = TorHttpClient(proxyHost: '127.0.0.1', proxyPort: 9050);

    try {
      final peerOnion = widget.peerId;
      final uri = Uri.parse("http://$peerOnion:80/message");
      final headers = {'Content-Type': 'application/json'};
      final body = jsonEncode({
        "id": id,
        "senderId": widget.userId,
        "receiverId": widget.peerId,
        "message": encrypted,
        "type": type,
        "fileName": fileName,
        "fileSize": fileSize,
        "replyTo": replyToId,
        "timestamp": DateTime.now().millisecondsSinceEpoch,
      });
      final response = await torClient.post(uri, headers, body);
      final responseText = await response.transform(utf8.decoder).join();
      print("Message sent: $responseText");

      return true;
    } 
    catch (e) {
      print("Failed to send message: $e");
      return false;
    } 
    finally {
      torClient.close();
    }
  }



  void _handleSend(dynamic message) {
    if (message is TextMessage && message.text.isNotEmpty) {
      _handleSendText(message.text);
    } else if (message is String && message.isNotEmpty) {
      _handleSendText(message);
    }
  }

  void _openChatProfile() async {
    final peerContact = Contact(
      id: widget.peerId,
      name: _peerName, // Use local copy
      avatarUrl: '',
      publicKeyPem: widget.peerPublicKeyPem ?? '',
    );

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatProfileScreen(
          peer: peerContact,
          currentUserName: widget.userName,
          onClose: () => Navigator.of(context).pop(),
          onUpdateName: (Contact updatedContact) async {
            // Update in database
            await DBHelper.insertOrUpdateUser({
              'id': updatedContact.id,
              'name': updatedContact.name,
              'avatarUrl': updatedContact.avatarUrl,
            });
            widget.reloadUsers();
          },
          onDeleteChat: () async {
            // Delete all messages between these users
            await MessagesDb.deleteMessagesBetween(
              widget.userId,
              widget.peerId,
            );
            // Refresh the message list
            resetChatState();
            setState(() {
              _messages = InMemoryChatController();
              _chatKey = UniqueKey();
            });
            _loadInitialMessages();
          },
          onDeleteContact: () async {
            // Delete contact from database
            await DBHelper.deleteUser(widget.peerId);
            // Close chat screen
            resetChatState();

            setState(() {
              _messages = InMemoryChatController();
              _chatKey = UniqueKey();
              _replyToMessage = null;

              // Instead of Navigator.pop(), just clear selectedContact to unmount ChatScreen 
            });
            
            widget.clearChat();
          },
        ),
      ),
    );

    // If a contact was updated, refresh the UI
    if (result != null && result is Contact) {
      setState(() {
        _peerName = result.name; // Update local copy
      });
    }
  }

  Color invertColor(Color color) {
    return Color.fromARGB(
      (color.a *255.0).round(),
      255 - (color.r *255.0).round(),
      255 - (color.g *255.0).round(),
      255 - (color.b *255.0).round(),
    );
  }

  Widget _buildReplyPreview() {
    if (_replyToMessage == null) return SizedBox.shrink();
    String previewText;
    if (_replyToMessage is TextMessage) {
      previewText = (_replyToMessage as TextMessage).text;
    } else if (_replyToMessage is ImageMessage) {
      previewText = '📷 Image';
    } else if (_replyToMessage is FileMessage) {
      previewText = '📎 File: ${(_replyToMessage as FileMessage).name}';
    } else {
      previewText = 'Unsupported message';
    }
    return Container(
      color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).colorScheme.secondary : Theme.of(context).colorScheme.primary,
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              previewText,
              style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white, fontStyle: FontStyle.italic),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(Icons.close),
            color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white,
            onPressed: () {
              setState(() {
                _replyToMessage = null;
              });
            },
          ),
        ],
      ),
    );
  }

  Future<void> deleteSelectedMessages() async {
   
    for (var id in selectedMessageIds) {
      await MessagesDb.deleteMessageById(id);
    }

    setState(() {
      for (var id in selectedMessageIds) {
        _messages.removeMessage(
          _messages.messages.firstWhere((msg) => msg.id == id)
        );
      }
      selectedMessageIds.clear(); // Clear selection after deletion
    });

  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 70,
        title: GestureDetector(
          onTap: () {
            showModalBottomSheet(
              context: context,
              builder: (BuildContext context) {
                return Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.all(16),
                        height: 4,
                        width: 40,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      ListTile(
                        leading: CircleAvatar(
                          radius: 20,
                          backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                          child: Text(
                            _peerName.isNotEmpty ? _peerName[0].toUpperCase() : 'U',
                            style: TextStyle(
                              color: Theme.of(context).primaryColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          _peerName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: const Text('View profile'),
                        onTap: () {
                          Navigator.pop(context);
                          _openChatProfile();
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                child: Text(
                  _peerName.isNotEmpty ? _peerName[0].toUpperCase() : 'U',
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).hintColor : Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _peerName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'GHOST',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark ? Theme.of(context).hintColor : Theme.of(context).primaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: 
          selectedMessageIds.isNotEmpty ?
            [
              IconButton(
                icon: Icon(Icons.delete),
                onPressed: deleteSelectedMessages,
              ),
              IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: _openChatProfile,
              ),
            ]
          : 
          [
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _openChatProfile,
            ),
          ]
        ,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 🟨 Show reply preview (if replying to a message)
            if (_replyToMessage != null)
              _buildReplyPreview(),

            // 🟩 Chat messages — takes up remaining space
            Expanded(
              child: Chat(
                key: _chatKey,
                chatController: _messages,
                currentUserId: widget.userId,
                theme: ChatTheme.fromThemeData(Theme.of(context)),
                resolveUser: (_) async => _user,
                onMessageSend: (message) {
                  _handleSend(message);
                },
                onMessageLongPress: (context, message, {LongPressStartDetails? details, int? index}) {
                  setState(() {
                    if (selectedMessageIds.contains(message.id)) {
                      selectedMessageIds.remove(message.id);
                    } else {
                      selectedMessageIds.add(message.id);
                    }
                  });
                },
                builders: Builders(
                  chatAnimatedListBuilder: (context, itemBuilder) {
                    return ChatAnimatedList(
                      itemBuilder: itemBuilder,
                      onEndReached: () async {
                        await _loadMoreMessages();
                      },
                    );
                  },
                  chatMessageBuilder: (
                    BuildContext context,
                    Message message,
                    int index,
                    Animation<double> animation,
                    Widget child, {
                    bool? isRemoved,
                    required bool isSentByMe,
                    MessageGroupStatus? groupStatus,
                  }) {
                    final msgDate = DateTime.fromMillisecondsSinceEpoch(message.createdAt!.millisecondsSinceEpoch);
                    final currentDay = DateTime(msgDate.year, msgDate.month, msgDate.day);

                    DateTime? prevDay;
                    if (index > 0 && index - 1 < _messages.messages.length) {
                      final prevMsg = _messages.messages[index - 1];
                      final prevDate = DateTime.fromMillisecondsSinceEpoch(prevMsg.createdAt!.millisecondsSinceEpoch);
                      prevDay = DateTime(prevDate.year, prevDate.month, prevDate.day);
                    }

                    bool showDateHeader = index == 0 || prevDay == null || !currentDay.isAtSameMomentAs(prevDay);

                    Widget replyPreviewWidget = const SizedBox.shrink();
                    final replyId = message.replyToMessageId;
                    if (replyId != null) {
                      Message? repliedMessage;
                      try {
                        repliedMessage = _messages.messages.firstWhere((m) => m.id == replyId);
                      } catch (_) {
                        repliedMessage = null;
                      }

                      if (repliedMessage != null) {
                        String previewText;
                        if (repliedMessage is TextMessage) {
                          previewText = repliedMessage.text;
                        } else if (repliedMessage is ImageMessage) {
                          previewText = '📷 Image';
                        } else if (repliedMessage is FileMessage) {
                          previewText = '📎 File: ${repliedMessage.name}';
                        } else {
                          previewText = 'Unsupported message';
                        }

                        replyPreviewWidget = Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                          child: Text(
                            previewText,
                            style: const TextStyle(
                              fontStyle: FontStyle.italic,
                              color: Colors.black54,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: isSentByMe ? TextAlign.right : TextAlign.left,
                          ),
                        );
                      }
                    }


                    bool isSelected = selectedMessageIds.contains(message.id);

                    return Column(
                      children: [
                        if (showDateHeader)
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            alignment: Alignment.center,
                            child: Text(
                              "${msgDate.day}/${msgDate.month}/${msgDate.year}",
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ),
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              double delta = details.delta.dx;
                              if (isSentByMe) delta = -delta;
                              _dragOffsets[message.id] = (_dragOffsets[message.id] ?? 0) + delta;
                              if (_dragOffsets[message.id]! < 0) _dragOffsets[message.id] = 0;
                              if (_dragOffsets[message.id]! > 100) _dragOffsets[message.id] = 100;
                            });
                          },
                          onHorizontalDragEnd: (details) {
                            setState(() {
                              if ((_dragOffsets[message.id] ?? 0) > 50) {
                                _replyToMessage = message;
                              }
                              _dragOffsets[message.id] = 0;
                            });
                          },
                          onLongPress: () {
                            setState(() {
                              if (isSelected) {
                                selectedMessageIds.remove(message.id);
                              } else {
                                selectedMessageIds.add(message.id);
                              }
                            });
                          },
                          child: Transform.translate(
                            offset: Offset(isSentByMe ? -(_dragOffsets[message.id] ?? 0) : (_dragOffsets[message.id] ?? 0), 0),
                            child: Container(
                              decoration: BoxDecoration(
                                color: selectedMessageIds.contains(message.id)
                                  ? Colors.blue.withAlpha(60)
                                  : Colors.transparent  
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                child: SizeTransition(
                                  sizeFactor: animation,
                                  child: Row(
                                    mainAxisAlignment: isSentByMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Flexible(
                                        child: Column(
                                          crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                          children: [
                                            replyPreviewWidget,
                                            child,
                                          ],
                                        ),
                                      ),
                                    ],
                                ),
                              ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                  fileMessageBuilder: fileMessageBuilder,
                  imageMessageBuilder: myImageMessageBuilder,

                  composerBuilder: (context) {
                    return (
                      Padding(padding: EdgeInsetsGeometry.all(0))
                    );
                  }
                ),
              ),
            ),

            // 🟦 Composer is fixed to bottom
            MessageComposer(onSendText: _handleSend, onSendImage: _handleSendImage, onSendFile: _handleSendFile),
          ],
        ),
      ),
    );
  }

  Widget myImageMessageBuilder(
    BuildContext context,
    ImageMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {

    

    final base64Str = message.source.contains('base64,')
      ? message.source.split('base64,')[1]
      : message.source;

    Uint8List bytes = base64Decode(base64Str);


    final msgDate = DateTime.fromMillisecondsSinceEpoch(message.createdAt!.millisecondsSinceEpoch);
    final timeString =
        "${msgDate.hour.toString().padLeft(2, '0')}:${msgDate.minute.toString().padLeft(2, '0')}";

    return Column(
      crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  backgroundColor: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white,
                  appBar: AppBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                  ),
                  body: Center(
                    child: InteractiveViewer(
                      child: Image.memory(bytes),
                    ),
                  ),
                ),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              width: max(200, (message.width?? 20) / 4),
              height: max(200, (message.height ?? 20 )/ 4),
              bytes,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          timeString,
          style: TextStyle(fontSize: 10, color: Colors.grey[600]),
        ),
      ],
    );
  }


  Widget fileMessageBuilder(
    BuildContext context,
    FileMessage message,
    int index, {
    required bool isSentByMe,
    MessageGroupStatus? groupStatus,
  }) {
    final maxWidth = MediaQuery.of(context).size.width * 0.4;
    print('displaying message file');
    final ValueNotifier<bool> isDownloading = ValueNotifier(false);

    Future<void> downloadBase64File() async {
      if (isDownloading.value == true) return;

      isDownloading.value = true;

      await Future.delayed(Duration(milliseconds: 50));
      try {
        if (message.source.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No encrypted data available for this file')),
          );
          return;
        }

        // decryptFileInBackground expects a Map with a 'message' field containing JSON string
        final Map<String, dynamic> decryptInput = {'message': message.source};

        Uint8List bytes = await decryptFileInBackground(decryptInput, widget.keyManager);

        Directory? dir;
        
        if (Platform.isAndroid) {
          dir = Directory("/storage/emulated/0/Download/");
        }
        else {
          dir = await getDownloadsDirectory();
        }
        File file = File('${dir!.path}/${message.name}');
        int c = 0;
        while (await file.exists()) {
          file = File('${dir.path}/${message.name} - $c');
          c++;
        }
        if (bytes.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${file.path.split("/").last} is still decrypting, please wait.')),
          );
          return;
        }
        await file.writeAsBytes(bytes);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Successfully downloaded ${file.path.split("/").last}')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error downloading file: $e')),
        );
      } finally {
        isDownloading.value = false;
      }
    }

    final msgDate = DateTime.fromMillisecondsSinceEpoch(message.createdAt!.millisecondsSinceEpoch);
    final timeString = "${msgDate.hour.toString().padLeft(2,'0')}:${msgDate.minute.toString().padLeft(2,'0')}";

    // Calculate file size in KB / MB
    String fileSizeString = '';
    if (message.size != null) {
      final sizeInKB = message.size! / 1024;
      if (sizeInKB < 1024) {
        fileSizeString = "${sizeInKB.toStringAsFixed(1)} KB";
      } else {
        fileSizeString = "${(sizeInKB / 1024).toStringAsFixed(1)} MB";
      }
    }

    return Column(
      crossAxisAlignment: isSentByMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: GestureDetector(
            onTap: downloadBase64File,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(225),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: isDownloading,
                    builder: (context, downloading, _) {
                      if (downloading) {
                        return SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black,
                            ),
                            strokeWidth: 2.5,
                          ),
                        );
                      } else {
                        return CircleAvatar(
                          backgroundColor: Theme.of(context).primaryColor.withAlpha(120),
                          child: Icon(
                            Icons.insert_drive_file,
                            size: 24,
                            color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[300] : Colors.white,
                          ),
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.name,
                          style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.black : Colors.white),
                          overflow: TextOverflow.visible,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            if (fileSizeString.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Text(
                                  fileSizeString,
                                  style: TextStyle(fontSize: 10, color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.white),
                                ),
                              ),
                            Text(
                              timeString,
                              style: TextStyle(fontSize: 10, color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.white),
                            ),
                          ],
                        )
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}