import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:convert/convert.dart' as convert;
import 'package:pointycastle/export.dart' as pc;
import 'key_manager.dart';
import 'wallet.dart';

void main() {
  runApp(const AptosDebugApp());
}

class AptosDebugApp extends StatelessWidget {
  const AptosDebugApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aptos Wallet Debug',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D4AA),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
      ),
      home: const RootPage(),
    );
  }
}

// ── Модель токена ─────────────────────────────────────────────
class TokenBalance {
  final String name;
  final String symbol;
  final double amount;
  final int decimals;
  final String assetType;

  TokenBalance({
    required this.name,
    required this.symbol,
    required this.amount,
    required this.decimals,
    required this.assetType,
  });
}