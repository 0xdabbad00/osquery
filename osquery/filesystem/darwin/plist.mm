/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */

#include <sstream>

#import <Foundation/Foundation.h>

#include <boost/filesystem/path.hpp>
#include <boost/property_tree/json_parser.hpp>

#include <osquery/filesystem.h>
#include <osquery/logger.h>

namespace pt = boost::property_tree;

typedef pt::ptree::value_type ptvalue;

namespace osquery {

/**
 * @brief Filter selected data types from deserialized property list.
 *
 * Since a property list supports a superset of JSON types we must pass
 * through each type, focusing on the dictionary and list containers, to
 * cherry-pick JSON-supported types. The resultant boost property tree will
 * serialize/deserialize into JSON. It is the most used data type in osquery.
 *
 * The filter functions support:
 * NSString, NSDate, NSNumber, YES, NO, NSArray, and NSDictionary.
 * For NSData the result will be base64 encoded as a string type.
 */
Status filterDictionary(id plist, const std::string& root, pt::ptree& tree);

/// See filterDictionary, the mimicked logic with a anonymous key more or less.
Status filterArray(id plist, const std::string& root, pt::ptree& tree);

Status filterDictionary(id plist, const std::string& root, pt::ptree& tree) {
  Status total_status = Status(0, "OK");
  for (id key in [plist allKeys]) {
    if (key == nil || ![key isKindOfClass:[NSString class]]) {
      // Unknown type as dictionary key, most likely a malformed plist.
      continue;
    }

    id value = [plist objectForKey:key];
    if (value == nil) {
      continue;
    }

    auto path_node = std::string([key UTF8String]);
    if ([value isKindOfClass:[NSString class]]) {
      tree.push_back(ptvalue(path_node, pt::ptree([value UTF8String])));
    } else if ([value isKindOfClass:[NSNumber class]]) {
      tree.push_back(
          ptvalue(path_node, pt::ptree([[value stringValue] UTF8String])));
    } else if ([value isKindOfClass:[NSArray class]]) {
      auto status = filterArray(value, path_node, tree);
      if (!status.ok()) {
        total_status = status;
      }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
      pt::ptree child;
      auto status = filterDictionary(value, "", child);
      if (!status.ok()) {
        total_status = status;
      }
      tree.push_back(ptvalue(path_node, child));
    } else if ([value isKindOfClass:[NSData class]]) {
      NSString* dataString = [value base64EncodedStringWithOptions:0];
      tree.push_back(ptvalue(path_node, pt::ptree([dataString UTF8String])));
    } else if ([value isKindOfClass:[NSDate class]]) {
      NSNumber* seconds =
          [[NSNumber alloc] initWithDouble:[value timeIntervalSince1970]];
      tree.push_back(
          ptvalue(path_node, pt::ptree([[seconds stringValue] UTF8String])));
    } else if ([value isEqual:@(YES)]) {
      tree.push_back(ptvalue(path_node, pt::ptree("true")));
    } else if ([value isEqual:@(NO)]) {
      tree.push_back(ptvalue(path_node, pt::ptree("false")));
    }
  }
  return total_status;
}

Status filterArray(id plist, const std::string& root, pt::ptree& tree) {
  Status total_status = Status(0, "OK");
  pt::ptree child_tree;
  for (id value in plist) {
    if (value == nil) {
      continue;
    }

    pt::ptree child;
    if ([value isKindOfClass:[NSString class]]) {
      child.put_value([value UTF8String]);
    } else if ([value isKindOfClass:[NSNumber class]]) {
      child.put_value([[value stringValue] UTF8String]);
    } else if ([value isKindOfClass:[NSArray class]]) {
      auto status = filterArray(value, "", child);
      if (!status.ok()) {
        total_status = status;
      }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
      auto status = filterDictionary(value, "", child);
      if (!status.ok()) {
        total_status = status;
      }
    } else if ([value isKindOfClass:[NSData class]]) {
      NSString* dataString = [value base64EncodedStringWithOptions:0];
      child.put_value([dataString UTF8String]);
    } else if ([value isKindOfClass:[NSDate class]]) {
      NSNumber* seconds =
          [[NSNumber alloc] initWithDouble:[value timeIntervalSince1970]];
      child.put_value([[seconds stringValue] UTF8String]);
    } else if ([value isEqual:@(YES)]) {
      child.put_value("true");
    } else if ([value isEqual:@(NO)]) {
      child.put_value("false");
    }
    child_tree.push_back(std::make_pair("", child));
  }
  tree.push_back(pt::ptree::value_type(root, child_tree));
  return total_status;
}

static inline Status filterPlist(NSData* plist, pt::ptree& tree) {
  if ([plist isKindOfClass:[NSDictionary class]]) {
    return filterDictionary((NSMutableDictionary*)plist, "", tree);
  } else {
    return filterArray((NSMutableArray*)plist, "root", tree);
  }
  return Status(0, "OK");
}

Status parsePlistContent(const std::string& content, pt::ptree& tree) {
  tree.clear();
  @autoreleasepool {
    id data = [NSData dataWithBytes:content.c_str() length:content.size()];
    if (data == nil) {
      return Status(1, "Unable to create plist content");
    }

    // Read file content into a data object, containing potential plist data.
    NSError* error = nil;
    id plist_data = [NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListImmutable
                      format:NULL
                       error:&error];
    if (plist_data == nil) {
      std::string error_message([[error localizedFailureReason] UTF8String]);
      VLOG(1) << error_message;
      return Status(1, error_message);
    }
    // Parse the plist data into a core foundation dictionary-literal.
    return filterPlist(plist_data, tree);
  }
}

Status parsePlist(const boost::filesystem::path& path, pt::ptree& tree) {
  tree.clear();
  Status status;
  @autoreleasepool {
    id ns_path = [NSString stringWithUTF8String:path.string().c_str()];
    id stream = [NSInputStream inputStreamWithFileAtPath:ns_path];
    if (stream == nil) {
      return Status(1, "Unable to read plist: " + path.string());
    }

    // Read file content into a data object, containing potential plist data.
    NSError* error = nil;
    [stream open];
    id plist_data = [NSPropertyListSerialization propertyListWithStream:stream
                                                                options:0
                                                                 format:NULL
                                                                  error:&error];
    if (plist_data == nil) {
      // The most common error is lack of read permissions.
      std::string error_message([[error localizedFailureReason] UTF8String]);
      VLOG(1) << error_message;
      [stream close];
      return Status(1, error_message);
    }
    // Parse the plist data into a core foundation dictionary-literal.
    status = filterPlist(plist_data, tree);
    [stream close];
  }
  return status;
}
}
