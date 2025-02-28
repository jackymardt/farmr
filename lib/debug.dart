import 'dart:core';
import 'package:farmr_client/config.dart';
import 'package:universal_io/io.dart' as io;
import 'dart:convert';

import 'package:logging/logging.dart';

import 'package:farmr_client/cache/cacheIO.dart'
    if (dart.library.js) "package:farmr_client/cache/cacheJS.dart";

import 'package:farmr_client/log/filter.dart';
import 'package:farmr_client/log/subslot.dart';
import 'package:farmr_client/log/logitem.dart';
import 'package:farmr_client/log/signagepoint.dart';
import 'package:farmr_client/log/shortsync.dart';
import 'package:yaml/yaml.dart';

final log = Logger('LOG');

enum ErrorType { Pool, Harvester }

class Log {
  ClientType _type;
  Cache _cache;
  String _binaryName;

  late String debugPath;
  late io.File _debugFile;
  late int _parseUntil;

  List<Filter> _filters = [];
  List<Filter> get filters => _filters;

  List<SignagePoint> signagePoints = [];

  //Generate list of complete/incomplete subslots from _signagePoints
  List<SubSlot> subSlots = [];

  List<ShortSync> shortSyncs = [];

  List<LogItem> poolErrors = [];
  List<LogItem> harvesterErrors = [];

  late final String floraProxy;

  Log(String logPath, this._cache, bool parseLogs, this._binaryName, this._type,
      String configPath) {
    _parseUntil = _cache.parseUntil;
    _filters = _cache.filters; //loads cached filters
    signagePoints = _cache.signagePoints; //loads cached subslots
    shortSyncs = _cache.shortSyncs;
    poolErrors = _cache.poolErrors;
    harvesterErrors = _cache.harvesterErrors;

    debugPath = logPath + "/debug.log";
    _debugFile = io.File(debugPath);

    if (_binaryName == "flora")
      floraProxy = "flora_proxy: ";
    else
      floraProxy = "";

    if (parseLogs) {
      loadLogItems();

      //if nothing was found then it
      //assumes log level is not set to info
      if (filters.length == 0 &&
          signagePoints.length == 0 &&
          shortSyncs.length == 0 &&
          _type != ClientType.HPool) {
        setLogLevelToInfo(configPath);
      }
      _cache.saveLogs(
          signagePoints, shortSyncs, filters, harvesterErrors, poolErrors);
    }
  }

  void setLogLevelToInfo(String configPath) {
    try {
      String configFile =
          configPath + io.Platform.pathSeparator + "config.yaml";

      var configYaml = loadYaml(
          io.File(configFile).readAsStringSync().replaceAll("!!set", ""));

      String logLevel = configYaml['farmer']['logging']['log_level'];

      if (logLevel == "WARNING") {
        //TODO: RENAME ALL THESE PRINTS TO LOG.WARNING
        print(
            "Log Parsing is enabled but $_binaryName's log level is set to $logLevel");
        print("Attempting to set $_binaryName's log level to INFO");

        io.Process.runSync(
            _cache.binPath, const ["configure", "--set-log-level", "INFO"]);

        configYaml = loadYaml(
            io.File(configFile).readAsStringSync().replaceAll("!!set", ""));

        logLevel = configYaml['farmer']['logging']['log_level'];

        if (logLevel == "INFO") {
          print("$_binaryName's log level has been set to INFO");
          print("Restarting $_binaryName's services");
          if (_type == ClientType.Farmer)
            io.Process.runSync(_cache.binPath, const ["start", "-r", "farmer"]);
          else if (_type == ClientType.Harvester)
            io.Process.runSync(
                _cache.binPath, const ["start", "-r", "harvester"]);

          print("Waiting for services to restart...");
          io.sleep(Duration(seconds: 60));
          loadLogItems();
        }
      }
    } catch (error) {}
  }

  loadLogItems() {
    bool keepParsing = true;
    bool keepParsingFilters = true;
    bool keepParsingSignagePoints = true;
    bool keepParsingShortSyncs = true;
    bool keepParsingPoolErrors = true;
    bool keepParsingHarvesterErrors = true;

    log.info("Started parsing logs");
    //parses debug.log
    //no longer parses all debug files (debug.log.1, debug.log.2, ...)
    if (keepParsing) {
      log.info("Started parsing debug.log");

      try {
        _debugFile = io.File(debugPath);

        //stops parsing once it reaches parseUntil date limit
        if (_debugFile.existsSync()) {
          String content;

          try {
            content = _debugFile.readAsStringSync();
          } catch (e) {
            var bytes = _debugFile.readAsBytesSync();

            //reads files this way because of UTF 16 decoding??
            content = utf8.decode(bytes, allowMalformed: true);
          }

          //parses filters
          if (keepParsingFilters) {
            log.info("Started parsing filters in debug.log");
            try {
              keepParsingFilters = _parseFilters(content, _parseUntil);
            } catch (e) {
              log.warning(
                  "Warning: could not parse filters in debug.log, make sure $_binaryName log level is set to INFO");
            }
            log.info(
                "Finished parsing filters in debug.log - keepParsingFilters: $keepParsingFilters");
          }

          //parses signage points
          if (keepParsingSignagePoints) {
            log.info("Started parsing Signage Points in debug.log");

            try {
              keepParsingSignagePoints =
                  _parseSignagePoints(content, _parseUntil);
            } catch (e) {
              log.info(
                  "Warning: could not parse SubSlots in debug.log, make sure $_binaryName log level is set to INFO");
            }

            log.info(
                "Finished parsing SignagePoints in debug.log - keepParsingSignagePoints: $keepParsingSignagePoints");
          }

          //parses signage points
          if (keepParsingShortSyncs) {
            log.info("Started parsing Short Sync events in debug.log");

            try {
              keepParsingShortSyncs = _parseShortSyncs(content, _parseUntil);
            } catch (e) {
              log.info(
                  "Warning: could not parse Short Sync events in debug.log, make sure $_binaryName log level is set to INFO");
            }

            log.info(
                "Finished Short Sync events in debug.log - keepParsingShortSyncs: $keepParsingShortSyncs");
          }

          //parses signage points
          if (keepParsingPoolErrors) {
            log.info("Started parsing Pool Errors events in debug.log");

            try {
              keepParsingPoolErrors =
                  _parseErrors(content, _parseUntil, ErrorType.Pool);
            } catch (e) {
              log.info(
                  "Warning: could not parse Pool Error events in debug.log, make sure $_binaryName log level is set to INFO");
            }

            log.info(
                "Finished pool error events in debug.log - keepParsingPoolErrors: $keepParsingPoolErrors");
          }

          //parses signage points
          if (keepParsingHarvesterErrors) {
            log.info("Started parsing Harvester Errors events in debug.log");

            try {
              keepParsingHarvesterErrors =
                  _parseErrors(content, _parseUntil, ErrorType.Harvester);
            } catch (e) {
              log.info(
                  "Warning: could not parse Harvester Error events in debug.log, make sure $_binaryName log level is set to INFO");
            }

            log.info(
                "Finished Harvester Error events in debug.log - keepParsingHarvesterErrors: $keepParsingHarvesterErrors");
          }
        }
      } catch (Exception) {
        log.warning(
            "Warning: could not parse debug.log, make sure $_binaryName log level is set to INFO");
      }

      //stops loading more files when all of the logging items stop parsing
      keepParsing = keepParsingFilters &&
          keepParsingSignagePoints &&
          keepParsingShortSyncs &&
          keepParsingPoolErrors &&
          keepParsingPoolErrors;

      log.info("Finished parsing debug.log - keepParsing: $keepParsing");
    }

    filterDuplicateFilters();
    filters.shuffle();

    filterDuplicateSignagePoints();
    _genSubSlots();

    filterDuplicateErrors();
  }

  //Parses debug file and looks for filters
  bool _parseFilters(String contents, int parseUntil) {
    bool keepParsing = true;
    bool inCache = false;

    try {
      RegExp filtersRegex = RegExp(
          "([0-9-]+)T([0-9:]+)\\.([0-9]+) harvester $floraProxy[a-z]+\\.harvester\\.harvester\\s*:\\s+INFO\\s+([0-9]+) plots were eligible for farming \\S+ Found ([0-9]+) proofs\\. Time: ([0-9\\.]+) s\\. Total ([0-9]+) plots",
          multiLine: true);

      var matches = filtersRegex.allMatches(contents).toList();

      int timestamp = DateTime.now().millisecondsSinceEpoch;

      for (int i = matches.length - 1; i >= 0; i--) {
        try {
          if (keepParsing && !inCache) {
            RegExpMatch match = matches[i];

            //Parses date from debug.log
            timestamp = parseTimestamp(match.group(1) ?? '1971-01-01',
                match.group(2) ?? '00:00:00', match.group(3) ?? '0000');

            //if filter's timestamp is outside parsing date rang
            keepParsing = timestamp > parseUntil;

            //if filter is in cache
            inCache = filters
                .any((cachedFilter) => cachedFilter.timestamp == timestamp);

            if (!inCache && keepParsing) {
              //print(timestamp);

              int eligiblePlots = int.parse(match.group(4) ?? '0');
              int proofs = int.parse(match.group(5) ?? '0');
              double time = double.parse(match.group(6) ?? '0.0');
              int totalPlots = int.parse(match.group(7) ?? '0');
              Filter filter =
                  Filter(timestamp, eligiblePlots, proofs, time, totalPlots);

              _filters.add(filter);
            }
          }
        } catch (Exception) {
          log.warning("Error parsing filters!");
        }
      }
    } catch (e) {
      log.warning(
          "Warning: could not parse filters, make sure $_binaryName log level is set to INFO");
    }

    return keepParsing & !inCache;
  }

  bool _parseSignagePoints(String contents, int parseUntil) {
    bool keepParsing = true;
    bool inCache = false;

    try {
      RegExp signagePointsRegex = RegExp(
          "([0-9-]+)T([0-9:]+)\\.([0-9]+) full_node $floraProxy[a-z]+\\.full\\_node\\.full\\_node\\s*:\\s+INFO\\W+Finished[\\S ]+ ([0-9]+)\\/64",
          multiLine: true);

      var matches = signagePointsRegex.allMatches(contents).toList();
      int timestamp = 0;

      for (int i = matches.length - 1; i >= 0; i--) {
        if (keepParsing && !inCache) {
          var match = matches[i];

          //Parses date from debug.log
          timestamp = parseTimestamp(match.group(1) ?? '1971-01-01',
              match.group(2) ?? '00:00:00', match.group(3) ?? '0000');

          //if filter's timestamp is outside parsing date rang
          keepParsing = timestamp > parseUntil;

          inCache = signagePoints
              .any((signagePoint) => signagePoint.timestamp == timestamp);

          //only adds subslot if its not already in cache
          if (keepParsing && !inCache) {
            int index = int.parse(match.group(4) ?? '0');

            SignagePoint signagePoint = SignagePoint(timestamp, index);
            signagePoints.add(signagePoint);
          }
        }
      }
    } catch (Exception) {
      log.info("Error parsing signage points.");
    }

    return keepParsing && !inCache;
  }

  _genSubSlots() {
    subSlots = [];
    //orders signage points by timestamps
    signagePoints.sort((s1, s2) => s1.timestamp.compareTo(s2.timestamp));

    for (SignagePoint signagePoint in signagePoints) {
      SubSlot? subSlot;

      if (signagePoint.index != 1) {
        try {
          subSlot = subSlots
              .where((point) =>
                  point.lastStep == signagePoint.index - 1 && !point.complete)
              .last;
        } catch (Exception) {
          //print(currentStep);
        }
      }

      if (subSlots.length == 0 || subSlot == null)
        subSlots.add(new SubSlot([signagePoint], subSlots.length == 0));
      else
        subSlot.addSignagePoint(signagePoint);
    }

    try {
      //Won't count with last SubSlot if it's incomplete
      if (!subSlots.last.complete) subSlots.removeLast();
    } catch (e) {}
  }

  bool _parseShortSyncs(String contents, int parseUntil) {
    bool keepParsing = true;
    bool inCache = false;

    try {
      RegExp shortSyncsRegex = RegExp(
          "([0-9-]+)T([0-9:]+)\\.([0-9]+) full_node $floraProxy[a-z]+\\.full\\_node\\.full\\_node\\s*:\\s+INFO\\W+Starting batch short sync from ([0-9]+) to height ([0-9]+)",
          multiLine: true);

      var matches = shortSyncsRegex.allMatches(contents).toList();
      int timestamp = 0;

      for (int i = matches.length - 1; i >= 0; i--) {
        if (keepParsing && !inCache) {
          var match = matches[i];

          //Parses date from debug.log
          timestamp = parseTimestamp(match.group(1) ?? '1971-01-01',
              match.group(2) ?? '00:00:00', match.group(3) ?? '0000');

          keepParsing = timestamp > parseUntil;

          inCache =
              shortSyncs.any((shortSync) => shortSync.timestamp == timestamp);

          //only adds subslot if its not already in cache
          if (keepParsing && !inCache) {
            int start = int.parse(match.group(4) ?? '1');
            int end = int.parse(match.group(5) ?? '2');

            ShortSync shortSync = ShortSync(timestamp, start, end);
            shortSyncs.add(shortSync);
          }
        }
      }
    } catch (Exception) {
      log.info("Error parsing short sync events.");
    }
    return keepParsing && !inCache;
  }

  //Parses debug file and looks for pool errors
  bool _parseErrors(String contents, int parseUntil, ErrorType type) {
    bool keepParsing = true;
    bool inCache = false;

    try {
      final errorText;

      switch (type) {
        case ErrorType.Pool:
          errorText = "Error sending partial to";
          break;
        case ErrorType.Harvester:
          errorText = "Harvester did not respond";
          break;
      }

      RegExp errorsRegex = RegExp(
          "([0-9-]+)T([0-9:]+)\\.([0-9]+) farmer $floraProxy[a-z]+\\.farmer\\.farmer\\s*:\\s+ERROR\\s+$errorText",
          multiLine: true);

      var matches = errorsRegex.allMatches(contents).toList();

      int timestamp = DateTime.now().millisecondsSinceEpoch;

      for (int i = matches.length - 1; i >= 0; i--) {
        try {
          if (keepParsing && !inCache) {
            RegExpMatch match = matches[i];

            //Parses date from debug.log
            timestamp = parseTimestamp(match.group(1) ?? '1971-01-01',
                match.group(2) ?? '00:00:00', match.group(3) ?? '0000');

            //if filter's timestamp is outside parsing date rang
            keepParsing = timestamp > parseUntil;

            //if filter is in cache
            inCache = (type == ErrorType.Pool ? poolErrors : harvesterErrors)
                .any((cached) => cached.timestamp == timestamp);

            if (!inCache && keepParsing) {
              //print(timestamp);

              LogItem error = LogItem(timestamp, LogItemType.Farmer);

              (type == ErrorType.Pool ? poolErrors : harvesterErrors)
                  .add(error);
            }
          }
        } catch (Exception) {
          log.warning("""Error parsing pool errors!
Ignore this warning if you are not farming in a pool.""");
        }
      }
    } catch (e) {
      log.warning(
          """Warning: could not parse pool errors, make sure $_binaryName log level is set to INFO
Ignore this warning if you are not farming in a pool.""");
    }

    return keepParsing & !inCache;
  }

  void filterDuplicateFilters() {
//Removes filters with same timestamps!
    final ids = _filters.map((filter) => filter.timestamp).toSet();
    _filters.retainWhere((filter) => ids.remove(filter.timestamp));
  }

  void filterDuplicateSignagePoints() {
//Removes subslots with same timestamps!
    final ids =
        signagePoints.map((signagePoint) => signagePoint.timestamp).toSet();
    signagePoints
        .retainWhere((signagePoint) => ids.remove(signagePoint.timestamp));
  }

  void filterDuplicateErrors() {
    final List<ErrorType> types = ErrorType.values;

    for (var type in types) {
//Removes pool/harvester errors with same timestamps!
      final ids = (type == ErrorType.Pool ? poolErrors : harvesterErrors)
          .map((error) => error.timestamp)
          .toSet();
      (type == ErrorType.Pool ? poolErrors : harvesterErrors)
          .retainWhere((error) => ids.remove(error.timestamp));
    }
  }
}
