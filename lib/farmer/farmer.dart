import 'dart:core';
import 'package:farmr_client/block.dart';
import 'package:farmr_client/blockchain.dart';
import 'package:farmr_client/farmer/status.dart';
import 'package:farmr_client/utils/rpc.dart';
import 'package:farmr_client/wallets/coldWallets/coldwallet.dart';
import 'package:farmr_client/wallets/coldWallets/localColdWallet-web.dart'
    if (dart.library.io) "package:farmr_client/wallets/coldWallets/localColdWallet.dart";
import 'package:farmr_client/wallets/localWallets/localWalletStruct.dart';
import 'package:farmr_client/wallets/poolWallets/genericPoolWallet.dart';
import 'package:universal_io/io.dart' as io;
import 'dart:convert';

import 'package:logging/logging.dart';

import 'package:farmr_client/config.dart';
import 'package:farmr_client/harvester/harvester.dart';
import 'package:farmr_client/debug.dart' as Debug;
import 'package:farmr_client/wallets/localWallets/localWalletJS.dart'
    if (dart.library.io) 'package:farmr_client/wallets/localWallets/localWalletIO.dart';
import 'package:farmr_client/farmer/connections.dart';
import 'package:farmr_client/log/shortsync.dart';
import 'package:http/http.dart' as http;

final log = Logger('Farmer');

class Farmer extends Harvester with FarmerStatusMixin {
  Connections? _connections;

  double get balance =>
      farmedBalance /
      blockchain.majorToMinorMultiplier; //hides balance if string

  //number of full nodes connected to farmer
  int _fullNodesConnected = 0;
  int get fullNodesConnected => _fullNodesConnected;

  List<CountryCount> _countriesConnected = [];
  List<CountryCount> get countriesConnected => _countriesConnected;

  @override
  late ClientType type;

  //SubSlots with 64 signage points
  int _completeSubSlots = 0;
  int get completeSubSlots => _completeSubSlots;

  //Signagepoints in an incomplete sub plot
  int _looseSignagePoints = 0;
  int get looseSignagePoints => _looseSignagePoints;

  List<ShortSync> shortSyncs = [];

  int _peakBlockHeight = -1;
  int get peakBlockHeight => _peakBlockHeight;

  //number of poolErrors events
  int _poolErrors = -1; // -1 means client doesnt support
  int get poolErrors => _poolErrors;

  //number of harvesterErrors events
  int _harvesterErrors = -1; // -1 means client doesnt support
  int get harvesterErrors => _harvesterErrors;

  String rootPath = "";

  @override
  Map toJson() {
    //loads harvester's map (since farmer is an extension of it)
    Map harvesterMap = (super.toJson());

    if (blockchain.config.showBalance) {
      harvesterMap.addEntries({
        'balance': balance //farmed balance
      }.entries);
    }

    //adds extra farmer's entries
    harvesterMap.addEntries({
      'completeSubSlots': completeSubSlots,
      'looseSignagePoints': looseSignagePoints,
      'fullNodesConnected': fullNodesConnected,
      'countriesConnected': _countriesConnected,
      "shortSyncs": shortSyncs,
      "netSpace": netSpace.size,
      "syncedBlockHeight": syncedBlockHeight,
      "peakBlockHeight": peakBlockHeight,
      "poolErrors": poolErrors,
      "harvesterErrors": harvesterErrors,
      "winnerBlocks": winnerBlocks
    }.entries);

    //returns complete map with both farmer's + harvester's entries
    return harvesterMap;
  }

  Farmer(
      {required Blockchain blockchain,
      String version = '',
      required this.type,
      required this.rootPath,
      bool firstInit = false})
      : super(blockchain, version) {
    if (type != ClientType.HPool) {
      getNodeHeight(); //sets _syncedBlockHeight

      //Parses logs for sub slots info
      if (blockchain.config.parseLogs) {
        calculateSubSlots(blockchain.log);
      }

      shortSyncs = blockchain.log.shortSyncs; //loads short sync events

      _poolErrors = blockchain.log.poolErrors.length;
      _harvesterErrors = blockchain.log.harvesterErrors.length;
    }
  }

  Future<void> _getLocalWallets() async {
    final bool? isWalletServiceRunning =
        ((await blockchain.rpcPorts?.isServiceRunning([RPCService.Wallet])) ??
            {})[RPCService.Wallet];

    //checks if wallet rpc service is running and wallet port is defined
    if (isWalletServiceRunning ?? false) {
      RPCConfiguration rpcConfig = RPCConfiguration(
          blockchain: blockchain,
          service: RPCService.Wallet,
          endpoint: "get_wallets",
          dataToSend: {});

      final walletsObject = await RPCConnection.getEndpoint(rpcConfig);

      RPCConfiguration rpcConfig7 = RPCConfiguration(
          blockchain: blockchain,
          service: RPCService.Wallet,
          endpoint: "get_public_keys",
          dataToSend: {"wallet_id": id});

      final fingerprintInfo = await RPCConnection.getEndpoint(rpcConfig7);

      List<dynamic> fingerprints = [];

      if (fingerprintInfo != null && (fingerprintInfo['success'] ?? false))
        fingerprints = fingerprintInfo['public_key_fingerprints'] ?? [];

      int walletHeight = -1;
      String name = "Wallet";
      bool synced = true;
      bool syncing = false;

      //if wallet balance is enabled and
      //if rpc works
      if (walletsObject != null && (walletsObject['success'] ?? false)) {
        // if (blockchain.config.showBalance &&
        //   walletsObject['wallets'].length > 0) farmedBalance = 0;

        for (var walletID in walletsObject['wallets'] ?? []) {
          final int type = walletID['type'] ?? 0;
          final int id = walletID['id'] ?? 1;

          name = walletID['name'] ?? "Wallet";
          String? address; //wallet address
          int? fingerprint;

          try {
            fingerprint =
                fingerprints[id - 1] is int ? fingerprints[id - 1] : null;
          } catch (error) {}
          //final int walletType = walletID['type'] ?? 0;

          RPCConfiguration rpcConfig2 = RPCConfiguration(
              blockchain: blockchain,
              service: RPCService.Wallet,
              endpoint: "get_wallet_balance",
              dataToSend: {"wallet_id": id});

          final walletInfo = await RPCConnection.getEndpoint(rpcConfig2);

          if (walletInfo != null && (walletInfo['success'] ?? false)) {
            final int confirmedBalance =
                walletInfo['wallet_balance']['confirmed_wallet_balance'] ?? 0;

            final int unconfirmedBalance =
                walletInfo['wallet_balance']['unconfirmed_wallet_balance'] ?? 0;

            RPCConfiguration rpcConfig3 = RPCConfiguration(
                blockchain: blockchain,
                service: RPCService.Wallet,
                endpoint: "get_sync_status",
                dataToSend: {"wallet_id": id});

            final walletSyncInfo = await RPCConnection.getEndpoint(rpcConfig3);

            if (walletSyncInfo != null &&
                (walletSyncInfo['success'] ?? false)) {
              synced = walletSyncInfo['synced'];
              syncing = walletSyncInfo['syncing'];
            }

            RPCConfiguration rpcConfig4 = RPCConfiguration(
                blockchain: blockchain,
                service: RPCService.Wallet,
                endpoint: "get_height_info",
                dataToSend: {"wallet_id": id});

            final walletHeightInfo =
                await RPCConnection.getEndpoint(rpcConfig4);

            if (walletHeightInfo != null &&
                (walletHeightInfo['success'] ?? false)) {
              walletHeight = walletHeightInfo['height'] ?? -1;
            }

            if (type != 9) {
              RPCConfiguration rpcConfig6 = RPCConfiguration(
                  blockchain: blockchain,
                  service: RPCService.Wallet,
                  endpoint: "get_next_address",
                  dataToSend: {"wallet_id": id, "new_address": false});

              final addressInfo = await RPCConnection.getEndpoint(rpcConfig6);

              if (addressInfo != null && (addressInfo['success'] ?? false))
                address = addressInfo['address'];
            }

            final LocalWallet wallet = LocalWallet(
                blockchain: blockchain,
                confirmedBalance:
                    blockchain.config.showWalletBalance ? confirmedBalance : -1,
                unconfirmedBalance: blockchain.config.showWalletBalance
                    ? unconfirmedBalance
                    : -1,
                walletHeight: walletHeight,
                syncedBlockHeight: syncedBlockHeight,
                name: name,
                status: (synced)
                    ? LocalWalletStatus.Synced
                    : (syncing)
                        ? LocalWalletStatus.Syncing
                        : LocalWalletStatus.NotSynced,
                addresses: address != null ? [address] : [],
                fingerprint: fingerprint);

            RPCConfiguration rpcConfig5 = RPCConfiguration(
                blockchain: blockchain,
                service: RPCService.Wallet,
                endpoint: "get_farmed_amount",
                dataToSend: {"wallet_id": id});

            final walletFarmedInfo =
                await RPCConnection.getEndpoint(rpcConfig5);

            if (walletFarmedInfo != null &&
                (walletFarmedInfo['success'] ?? false)) {
              //adds wallet farmed balance
              //WARNING THIS IS NOT REALLY WORKING
              // CHIA RPC IS BROKEN
              /* if (blockchain.config.showBalance)
                farmedBalance += walletFarmedInfo['farmed_amount'] as int;*/
              //sets wallet last farmed height
              wallet.setLastBlockFarmed(walletFarmedInfo['last_height_farmed']);
            }

            wallet.getAllAddresses();

            wallets.add(wallet);
          }
        }
      } else //legacy wallet method
        _getLegacyLocalWallets();
    } else
      _getLegacyLocalWallets();

    for (String address in blockchain.config.coldWalletAddresses) {
      wallets.add(LocalColdWallet(
          blockchain: blockchain, address: address, rootPath: rootPath));
    }

    await _verifyRewardAddresses();
  }

  //checks if any of the local addresses / cold addresses match reward addresses
  Future<void> _verifyRewardAddresses() async {
    try {
      //print(addresses);

      //gets farmer/pool reward addresses from rpc
      final RPCConfiguration rpcConfig = RPCConfiguration(
          blockchain: blockchain,
          service: RPCService.Farmer,
          endpoint: "get_reward_targets",
          dataToSend: const {"search_for_private_key": false});

      final rewardsInfo = await RPCConnection.getEndpoint(rpcConfig);

      //print(rewardsInfo);

      if (rewardsInfo != null) {
        if (rewardsInfo['success'] ?? false) {
          farmerRewardAddress = rewardsInfo['farmer_target'];
          poolRewardAddress = rewardsInfo['pool_target'];

          final Map<String, String> targets = {
            "Farmer": farmerRewardAddress,
            "Pool": poolRewardAddress
          };

          //print(targets);

          //wars user if these addresses do not match hot/cold wallet address
          for (var target in targets.entries) {
            if (!addresses.contains(target.value)) log.warning("""
WARNING: ${target.key} rewards address ${target.value} does not match any of your hot/cold wallet addresses
Make sure that you have access to the wallet associated to this wallet address.
""");
          }
        } else
          throw Exception("success: ${rewardsInfo['success']}");
      } else
        throw Exception("RPC error: get_reward_targets failed");
    } catch (error) {
      log.info("Failed to verify reward addresses");
      log.info(error);
    }
  }

  Future<void> _getWinnerPlots() async {
    final List<Block> farmedBlocks = walletAggregate.farmedBlocks;

    //places null timestamps at the end of list
    farmedBlocks.sort((a, b) {
      int result;
      if (a.timestamp == null) {
        result = 1;
      } else if (b.timestamp == null) {
        result = -1;
      } else {
        // Ascending Order
        result = a.timestamp!.compareTo(b.timestamp!);
      }
      return result;
    });

    for (final farmedBlock in farmedBlocks) {
      //doesnt add block twice
      if (!winnerBlocks.map((e) => e.height).contains(farmedBlock.height)) {
        //https://github.com/Chia-Network/chia-blockchain/wiki/RPCExamples#11-get-block-record-by-height
        final RPCConfiguration getBlockRecordByHeight = RPCConfiguration(
            blockchain: blockchain,
            service: RPCService.Full_Node,
            endpoint: "get_block_record_by_height",
            dataToSend: {"height": farmedBlock.height});

        final dynamic result =
            await RPCConnection.getEndpoint(getBlockRecordByHeight);

        if ((result != null) && (result['success'] ?? false)) {
          final String headerHash = result['block_record']['header_hash'];

          //https://github.com/Chia-Network/chia-blockchain/wiki/RPCExamples#12-get-block
          final RPCConfiguration getWonBlockPublicKey = RPCConfiguration(
              blockchain: blockchain,
              service: RPCService.Full_Node,
              endpoint: "get_block",
              dataToSend: {"header_hash": headerHash});
          final dynamic result2 =
              await RPCConnection.getEndpoint(getWonBlockPublicKey);

          if (result2 != null && (result2['success'] ?? false)) {
            final dynamic plotPublicKey = result2['block']['reward_chain_block']
                ['proof_of_space']['plot_public_key'];

            if (plotPublicKey is String) {
              farmedBlock.plotPublicKey = plotPublicKey;

              //adds farmed block with plot public key to list of winner blocks in farmer
              winnerBlocks.add(farmedBlock);
            }
          }
        }
      }
    }
  }

  //legacy mode for getting local wallet
  //basically uses cli (chia wallet show)
  void _getLegacyLocalWallets() {
    LocalWallet localWallet = LocalWallet(
        blockchain: this.blockchain, syncedBlockHeight: syncedBlockHeight);
    localWallet.setLastBlockFarmed(lastBlockFarmed);

    //parses chia wallet show for wallet balance (legacy mode)
    if (blockchain.config.showWalletBalance)
      localWallet.parseWalletBalance(blockchain.config.cache!.binPath);

    wallets.add(localWallet);
  }

  void getNodeHeight() {
    try {
      var nodeOutput = io.Process.runSync(
              blockchain.config.cache!.binPath, const ["show", "-s"])
          .stdout
          .toString();

      RegExp regExp = RegExp(r"Height:[\s]+([0-9]+)");

      syncedBlockHeight =
          int.tryParse(regExp.firstMatch(nodeOutput)?.group(1) ?? "-1") ?? -1;
    } catch (error) {
      log.warning("Failed to get synced height");
    }
  }

  Future<void> _getPeakHeight() async {
    //tries to get peak block height from all the blocks
    try {
      final String url =
          "https://api.alltheblocks.net/${blockchain.allTheBlocksName}/block?pageNumber=0&pageSize=1";

      String contents = await http.read(Uri.parse(url));

      dynamic object = jsonDecode(contents);

      _peakBlockHeight =
          int.tryParse((object['content'][0]['height'] ?? -1).toString()) ?? -1;
    } catch (error) {
      log.info("Failed to get peak height for ${blockchain.currencySymbol}");
    }
  }

  @override
  Future<void> init() async {
    if (type != ClientType.HPool) {
      //initializes connections and counts peers
      _connections = await Connections.generateConnections(blockchain);
      await _connections?.getCountryCodes();

      _fullNodesConnected = _connections?.connections
              .where((connection) => connection.type == ConnectionType.FullNode)
              .length ??
          0; //whats wrong with this vscode formatting lmao

      _countriesConnected = _connections?.countryCount ?? [];

      await updateFarmerStatus(blockchain);

      await _getLocalWallets();

      await _getPeakHeight(); // attempts to get peak height
      //only works for blockchains supported by alltheblocks.net

    }

    await super.init();

    await _getWinnerPlots();
  }

  //Server side function to read farm from json file
  Farmer.fromJson(dynamic object) : super.fromJson(object) {
    type = ClientType.Farmer;

    statusFromJson(object, blockchain);

    int walletBalance = -1;
    double daysSinceLastBlock = -1.0;

    //initializes wallet with given balance and number of days since last block
    if (object['walletBalance'] != null)
      walletBalance =
          (double.parse(object['walletBalance'].toString()) * 1e12).round();
    if (object['daysSinceLastBlock'] != null)
      daysSinceLastBlock =
          double.parse(object['daysSinceLastBlock'].toString());

    if (object['syncedBlockHeight'] != null)
      syncedBlockHeight = object['syncedBlockHeight'];

    if (object['peakBlockHeight'] != null)
      _peakBlockHeight = object['peakBlockHeight'];

    int walletHeight = -1;
    if (object['walletHeight'] != null) walletHeight = object['walletHeight'];

    //pool wallet LEGACY
    if (object['pendingBalance'] != null && object['collateralBalance'] != null)
      wallets.add(GenericPoolWallet(
          pendingBalance: (double.parse(object['pendingBalance'].toString()) *
                  blockchain.majorToMinorMultiplier)
              .round(),
          collateralBalance:
              (double.parse(object['collateralBalance'].toString()) *
                      blockchain.majorToMinorMultiplier)
                  .round(),
          blockchain: blockchain));
    //local wallet LEGACY
    if (walletBalance >= 0 || daysSinceLastBlock > 0)
      wallets.add(LocalWallet(
          confirmedBalance: walletBalance,
          daysSinceLastBlock: daysSinceLastBlock,
          blockchain: Blockchain.fromSymbol(object['crypto'] ?? "xch"),
          syncedBlockHeight: syncedBlockHeight,
          walletHeight: walletHeight));

    if (object['completeSubSlots'] != null)
      _completeSubSlots = object['completeSubSlots'];
    if (object['looseSignagePoints'] != null)
      _looseSignagePoints = object['looseSignagePoints'];

    if (object['fullNodesConnected'] != null)
      _fullNodesConnected = object['fullNodesConnected'];

    if (object['shortSyncs'] != null) {
      for (var shortSync in object['shortSyncs'])
        shortSyncs.add(ShortSync.fromJson(shortSync));
    }

    if (object['poolErrors'] != null) _poolErrors = object['poolErrors'];
    if (object['harvesterErrors'] != null)
      _harvesterErrors = object['harvesterErrors'];

    if (object['coldWallet'] != null) {
      double netBalance =
          double.parse((object['coldWallet']['netBalance'] ?? "-1").toString());
      double grossBalance = double.parse(
          (object['coldWallet']['grossBalance'] ?? "-1").toString());
      double farmedBalance = double.parse(
          (object['coldWallet']['farmedBalance'] ?? "-1").toString());

      wallets.add(ColdWallet(
          blockchain: Blockchain.fromSymbol(object['crypto'] ?? "xch"),
          netBalance: (netBalance * 1e12).round(),
          farmedBalance: (farmedBalance * 1e12).round(),
          grossBalance: (grossBalance * 1e12).round()));
    }

    calculateFilterRatio(this);

    if (object['countriesConnected'] != null) {
      for (var countryConnected in object['countriesConnected'])
        _countriesConnected.add(CountryCount.fromJson(countryConnected));
    }

    if (object['winnerPlots'] != null)
      for (final winnerPlot in object['winnerPlots'])
        if (winnerPlot is String)
          winnerBlocks.add(Block(plotPublicKey: winnerPlot));

    if (object['winnerBlocks'] != null)
      for (final winnerBlock in object['winnerBlocks'])
        winnerBlocks.add(Block.fromJson(winnerBlock));
  }

  //Adds harvester's plots into farm's plots
  void addHarvester(Harvester harvester) {
    super.addHarvester(harvester);

    if (harvester is Farmer) {
      _completeSubSlots += harvester.completeSubSlots;
      _looseSignagePoints += harvester._looseSignagePoints;

      winnerBlocks.addAll(harvester.winnerBlocks);

      shortSyncs.addAll(harvester.shortSyncs);
    }
  }

  void calculateSubSlots(Debug.Log log) {
    _completeSubSlots = log.subSlots.where((point) => point.complete).length;

    var incomplete = log.subSlots.where((point) => !point.complete);
    _looseSignagePoints = 0;
    for (var i in incomplete) {
      _looseSignagePoints += i.signagePoints.length;
    }
  }
}
