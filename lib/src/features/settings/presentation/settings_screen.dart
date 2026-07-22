import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final Future<PackageInfo> _packageInfoFuture;

  // Which account provider (if any) the current session is linked to, from
  // GET /auth/me. Null until checked, or if not signed in.
  String? _linkedProvider;
  String? _linkedUsername;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
    if (kIsWeb) {
      _checkAuthStatus();
    }
  }

  Future<void> _checkAuthStatus() async {
    final url = AppConfig.apiUrl('/auth/me');
    if (url.isEmpty) return;
    try {
      final response = await Dio().get(
        url,
        options: Options(extra: {'withCredentials': true}),
      );
      final data = response.data;
      if (data is Map && data['authenticated'] == true) {
        final user = data['user'];
        if (user is Map && mounted) {
          setState(() {
            _linkedProvider = user['provider'] as String?;
            _linkedUsername = user['username'] as String?;
          });
        }
      }
    } catch (_) {
      // Not signed in, offline, or the endpoint is unreachable - leave
      // as not-linked rather than surfacing an error here.
    }
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      debugPrint('Could not launch $url');
    }
  }

  Future<void> _sendEmail() async {
    final Uri emailLaunchUri = Uri(
      scheme: 'mailto',
      path: 'admin@sklabs.us',
      query: 'subject=MyMate AI Support Request',
    );
    if (await canLaunchUrl(emailLaunchUri)) {
      await launchUrl(emailLaunchUri);
    }
  }

  Future<void> _requestReview() async {
    final InAppReview inAppReview = InAppReview.instance;
    if (await inAppReview.isAvailable()) {
      inAppReview.requestReview();
    } else {
      // Platform specific store listing
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        inAppReview.openStoreListing(appStoreId: '6739669562');
      } else {
        // Android uses package name automatically
        inAppReview.openStoreListing();
      }
    }
  }

  void _showInstagramComingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Instagram login is coming soon.')),
    );
  }

  Future<void> _logout() async {
    final url = AppConfig.apiUrl('/auth/logout');
    if (url.isEmpty) return;
    // Same-tab navigation: the worker clears the session cookie and redirects
    // back, so the app reloads signed out.
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
  }

  Future<void> _connectGoogle() async {
    final returnTo = kIsWeb
        ? Uri.base.toString()
        : 'mymate://settings?google=connected';
    // Pass along the pre-login anonymous user id so the backend can merge
    // this device's existing chat history onto the linked account.
    final prefs = await SharedPreferences.getInstance();
    final anonId = prefs.getString('user_id');
    final authUrl = AppConfig.googleAuthUrl(returnTo, anonId: anonId);
    if (authUrl.isEmpty) return;
    // Navigate in the same tab (not a new one) so the browser doesn't treat
    // this as a popup - launchUrl after an awaited canLaunchUrl check loses
    // the user-gesture context that window.open() needs to avoid being
    // silently blocked.
    await launchUrl(Uri.parse(authUrl), webOnlyWindowName: '_self');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Dark theme background
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Settings',
          style: GoogleFonts.playfairDisplay(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!AppConfig.isFreeTier) ...[
              _buildSectionHeader('PREMIUM'),
              _buildSettingsTile(
                context,
                icon: Icons.diamond_outlined,
                title: 'Unlock Unlimited Access',
                subtitle: 'Get unlimited messages & roleplay',
                iconColor: Colors.pinkAccent,
                onTap: () {
                  context.push('/paywall');
                },
              ),
              const SizedBox(height: 30),
            ],

            if (kIsWeb) ...[
              _buildSectionHeader('ACCOUNT'),
              _buildSettingsTile(
                context,
                icon: Icons.g_mobiledata,
                title: _linkedProvider == 'google'
                    ? 'Connected with Google'
                    : 'Continue with Google',
                subtitle: _linkedProvider == 'google'
                    ? 'Linked${_linkedUsername != null ? ' as $_linkedUsername' : ''}'
                    : 'Keep your companion history between sessions and devices.',
                iconColor: Colors.pinkAccent,
                onTap: _connectGoogle,
                trailing: _linkedProvider == 'google'
                    ? const Icon(Icons.check_circle, color: Colors.greenAccent)
                    : null,
              ),
              _buildSettingsTile(
                context,
                icon: Icons.camera_alt_outlined,
                title: _linkedProvider == 'instagram'
                    ? 'Connected with Instagram'
                    : 'Continue with Instagram',
                subtitle: _linkedProvider == 'instagram'
                    ? 'Linked${_linkedUsername != null ? ' as $_linkedUsername' : ''}'
                    : 'Keep your companion history between sessions and devices. WIP',
                iconColor: Colors.pinkAccent,
                onTap: _showInstagramComingSoon,
                trailing: _linkedProvider == 'instagram'
                    ? const Icon(Icons.check_circle, color: Colors.greenAccent)
                    : null,
              ),
              if (_linkedProvider != null)
                _buildSettingsTile(
                  context,
                  icon: Icons.logout,
                  title: 'Sign out',
                  subtitle: 'Disconnect this account on this device',
                  iconColor: Colors.white70,
                  onTap: _logout,
                ),
              if (_linkedProvider == null)
                _buildBenefitsCard([
                  'Restore your chats when you come back',
                  'Keep the same companion identity across browsers',
                  'Protect your message history if browser storage is cleared',
                  'Make future premium access easier to recognize',
                ]),

              const SizedBox(height: 30),
            ],
            _buildSectionHeader('SUPPORT'),
            _buildSettingsTile(
              context,
              icon: Icons.star_outline,
              title: 'Rate Us',
              subtitle: 'Love the app? Let us know!',
              onTap: _requestReview,
            ),
            _buildSettingsTile(
              context,
              icon: Icons.mail_outline,
              title: 'Contact Support',
              subtitle: 'We are here to help',
              onTap: _sendEmail,
            ),

            const SizedBox(height: 30),
            _buildSectionHeader('LEGAL'),
            _buildSettingsTile(
              context,
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              onTap: () =>
                  _launchUrl('https://sites.google.com/view/mymateapp'),
            ),
            _buildSettingsTile(
              context,
              icon: Icons.description_outlined,
              title: 'Terms of Use',
              onTap: () =>
                  _launchUrl('https://sites.google.com/view/mymate-terms'),
            ),

            const SizedBox(height: 30),
            _buildSectionHeader('ABOUT'),
            FutureBuilder<PackageInfo>(
              future: _packageInfoFuture,
              builder: (context, snapshot) {
                final packageInfo = snapshot.data;
                return _buildAboutCard(
                  version: packageInfo == null
                      ? 'Loading...'
                      : '${packageInfo.version} (${packageInfo.buildNumber})',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15, left: 5),
      child: Text(
        title,
        style: GoogleFonts.lato(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    Color? iconColor,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E), // Dark card color
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (iconColor ?? Colors.white).withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: iconColor ?? Colors.white, size: 24),
        ),
        title: Text(
          title,
          style: GoogleFonts.lato(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle,
                style: GoogleFonts.lato(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              )
            : null,
        trailing: trailing ??
            (onTap == null
                ? null
                : Icon(
                    Icons.chevron_right,
                    color: Colors.white.withValues(alpha: 0.3),
                  )),
      ),
    );
  }

  Widget _buildBenefitsCard(List<String> benefits) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: benefits.map((benefit) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  color: Colors.pinkAccent,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    benefit,
                    style: GoogleFonts.lato(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 13,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAboutCard({
    required String version,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          _buildInfoRow('Version', version),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: GoogleFonts.lato(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.lato(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

}
