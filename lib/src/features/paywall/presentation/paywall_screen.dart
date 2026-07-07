import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/revenue_cat_service.dart';

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  final RevenueCatService _revenueCat = RevenueCatService();
  bool _available = false;
  List<Package> _packages = [];
  bool _loading = true;
  bool _purchasePending = false;

  @override
  void initState() {
    super.initState();
    _initStoreInfo();
  }

  Future<void> _initStoreInfo() async {
    setState(() {
      _loading = true;
      _available = false;
    });

    try {
      Offerings? offerings = await _revenueCat.getOfferings();
      
      // FALLBACK LOGIC: If current is null, try to find any available offering
      Offering? selectedOffering = offerings?.current;
      if (selectedOffering == null && offerings?.all.isNotEmpty == true) {
         // If no default "current" offering is configured, pick the first one available
         // This protects against misconfiguration in RevenueCat
         selectedOffering = offerings!.all.values.first;
         debugPrint('[Paywall] No "Current" offering found. Falling back to: ${selectedOffering.identifier}');
      }

      if (selectedOffering != null && selectedOffering.availablePackages.isNotEmpty) {
          final packages = List<Package>.from(selectedOffering.availablePackages);
          
          // Sort packages if needed
          packages.sort((a, b) {
             if (a.identifier.toLowerCase().contains('weekly')) return -1;
             if (b.identifier.toLowerCase().contains('weekly')) return 1;
             if (a.identifier.toLowerCase().contains('monthly')) return -1;
             if (b.identifier.toLowerCase().contains('monthly')) return 1;
             return 0; 
          });

          if (mounted) {
            setState(() {
              _available = true;
              _packages = packages;
              _loading = false;
            });
          }
      } else {
        debugPrint('[Paywall] No packages found in selected offering.');
        if (mounted) {
           setState(() {
             _available = false;
             _packages = [];
             _loading = false;
           });
        }
      }
    } catch (e) {
      debugPrint('[Paywall] Error initializing store info: $e');
      if (mounted) {
        setState(() {
          _available = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _buyPackage(Package package) async {
    setState(() {
      _purchasePending = true;
    });

    final success = await _revenueCat.purchasePackage(package);

    if (mounted) {
      setState(() {
        _purchasePending = false;
      });

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Welcome inside, my love.')),
        );
         // Update Premium Status Globally
         ref.read(userSubscriptionProvider.notifier).setPremium(true);
         if (mounted) context.pop();
      } else {
         ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Purchase failed or cancelled.')),
         );
      }
    }
  }
  
  Future<void> _restorePurchases() async {
     setState(() {
      _purchasePending = true;
    });
    
    final success = await _revenueCat.restorePurchases();
    
    if (mounted) {
       setState(() {
        _purchasePending = false;
      });
      
      if (success) {
         ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Purchases restored successfully.')),
        );
         ref.read(userSubscriptionProvider.notifier).setPremium(true);
         if (mounted) context.pop();
      } else {
         ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('No active subscriptions found to restore.')),
         );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => context.pop(),
        ),
      ),
      body: Stack(
        children: [
          // Background Image/Gradient
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF2E003E), // Deep dark purple
                    theme.primaryColor.withOpacity(0.4),
                    Colors.black,
                  ],
                ),
              ),
            ),
          ),
          
          // Content
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.primaryColor.withOpacity(0.2),
                    ),
                    child: Icon(Icons.diamond, size: 48, color: theme.primaryColor),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'UNLOCK EVERYTHING',
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Experience unlimited intimacy without boundaries.',
                    style: GoogleFonts.lato(
                      color: Colors.white70,
                      fontSize: 16,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  
                  const SizedBox(height: 30),
                  _buildBenefitRow("Unlimited Messages & Roleplay"),
                  _buildBenefitRow("Access All Character Personalities"),
                  _buildBenefitRow("Faster & Smarter AI Responses"),
                  _buildBenefitRow("No Ads, Pure Romance"),
                  
                  const SizedBox(height: 40),

                  if (_loading)
                    const Center(child: CircularProgressIndicator(color: Colors.pink))
                  else if (!_available || _packages.isEmpty)
                     Column(
                        children: [
                          const Text(
                            'Store Unavailable',
                            style: TextStyle(color: Colors.white, fontSize: 16),
                          ),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _initStoreInfo,
                            icon: const Icon(Icons.refresh, color: Colors.white),
                            label: const Text('Retry', style: TextStyle(color: Colors.white)),
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.2),
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            ),
                          )
                        ],
                     )
                  else
                    ..._packages.map((package) {
                      final product = package.storeProduct;
                      // Determine custom metadata based on Package identifier or Product ID
                      // Assuming package identifier contains weekly/monthly/yearly
                      String customDesc = "";
                      String badge = "";
                      bool isPromoted = false;
                      
                      final id = package.identifier.toLowerCase();

                      if (id.contains('weekly')) {
                        customDesc = "Enjoy weekly unlimited conversation";
                      } else if (id.contains('monthly')) {
                        customDesc = "Enjoy monthly unlimited conversation";
                        badge = "POPULAR";
                        isPromoted = true;
                      } else if (id.contains('yearly') || id.contains('annual')) {
                        customDesc = "Enjoy yearly unlimited conversation";
                        badge = "BEST VALUE";
                        isPromoted = true;
                      }

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: _buildProductCard(
                          theme, 
                          package, 
                          customDesc: customDesc,
                          badge: badge,
                          isHighlight: isPromoted,
                        ),
                      );
                    }).toList(),

                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: _purchasePending ? null : _restorePurchases,
                    child: Text(
                      'Restore Purchases',
                      style: TextStyle(color: Colors.white.withOpacity(0.5)),
                    ),
                  ),
                  const SizedBox(height: 20),
                   if (_purchasePending)
                    const Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildBenefitRow(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.pinkAccent, size: 20),
          const SizedBox(width: 12),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildProductCard(
    ThemeData theme, 
    Package package, 
    {String customDesc = "", String badge = "", bool isHighlight = false}
  ) {
      final product = package.storeProduct;
      final borderColor = isHighlight ? theme.primaryColor : Colors.white.withOpacity(0.2);
      final bgColor = isHighlight ? theme.primaryColor.withOpacity(0.15) : Colors.white.withOpacity(0.05);

      return InkWell(
          onTap: _purchasePending ? null : () => _buyPackage(package),
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: borderColor, width: isHighlight ? 2 : 1),
                ),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                        Expanded(
                          child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                    Text(
                                      product.title.replaceAll(RegExp(r'\(.*\)'), '').trim(), // Remove (App Name) from title
                                      style: GoogleFonts.playfairDisplay(
                                        fontWeight: FontWeight.bold, 
                                        color: Colors.white, 
                                        fontSize: 18
                                      )
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      customDesc.isNotEmpty ? customDesc : product.description,
                                      style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
                                      maxLines: 2, 
                                      overflow: TextOverflow.ellipsis
                                    ),
                                ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                             Text(
                               product.priceString, 
                               style: GoogleFonts.lato(
                                 fontSize: 20, 
                                 color: Colors.white, 
                                 fontWeight: FontWeight.bold
                               )
                             ),
                            if (package.identifier.toLowerCase().contains('yearly') || package.identifier.toLowerCase().contains('annual')) ...[
                               const SizedBox(height: 4),
                               Text(
                                  '/ year',
                                  style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                               ),
                            ]
                          ],
                        ),
                    ],
                ),
              ),
              if (badge.isNotEmpty)
                Positioned(
                  top: -10,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.primaryColor,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                         BoxShadow(color: theme.primaryColor.withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 4))
                      ]
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
      );
  }
}

