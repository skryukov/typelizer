# frozen_string_literal: true

module Typelizer
  # Sorts union type members within TypeScript type strings.
  # Handles types like "Type3 | Type1 | Type2" -> "Type1 | Type2 | Type3"
  # Also handles complex nested types like "Array<Type3 | Type1>" -> "Array<Type1 | Type3>"
  module UnionTypeSorter
    # Sorts union type members in a type string
    # @param type_str [String] The type string potentially containing unions
    # @param sort_order [Symbol, Proc, nil] The sort order (:none, :alphabetical, or Proc)
    # @return [String] The type string with sorted union members
    def self.sort(type_str, sort_order)
      return type_str if type_str.nil? || type_str.empty?

      case sort_order
      when :none, nil
        type_str
      when :alphabetical
        sort_unions_alphabetically(type_str)
      when Proc
        result = sort_order.call(type_str)
        result.is_a?(String) ? result : type_str
      else
        type_str
      end
    rescue => e
      Typelizer.logger.warn("UnionTypeSorter error: #{e.message}, preserving original order")
      type_str
    end

    # Sorts union members alphabetically while preserving structure
    # @param type_str [String] The type string to sort
    # @return [String] The sorted type string
    def self.sort_unions_alphabetically(type_str)
      # Handle the string by sorting unions at each level
      # We need to be careful with nested generics like Array<A | B | C>

      result = type_str.dup

      # First, handle unions inside angle brackets (generics)
      # Match content inside < > and sort unions within
      result = result.gsub(/<([^<>]+)>/) do |match|
        inner = Regexp.last_match(1)
        sorted_inner = sort_simple_union(inner)
        "<#{sorted_inner}>"
      end

      # Then handle any remaining top-level unions
      # But avoid sorting if the string has unbalanced brackets
      if balanced_brackets?(result)
        result = sort_top_level_union(result)
      end

      result
    end

    # Sorts a simple union string (no nested generics)
    # @param union_str [String] String like "Type3 | Type1 | Type2"
    # @return [String] Sorted string like "Type1 | Type2 | Type3"
    def self.sort_simple_union(union_str)
      return union_str unless union_str.include?("|")

      parts = split_union_members(union_str)
      return union_str if parts.size <= 1

      # Sort while preserving special cases:
      # - 'null' should typically stay at the end
      # - Keep the relative order of complex nested types
      regular_parts, null_parts = parts.partition { |p| p.strip.downcase != "null" }

      sorted_regular = regular_parts.sort_by { |p| p.strip.downcase }
      (sorted_regular + null_parts).join(" | ")
    end

    # Sorts top-level union (handles cases where unions aren't inside generics)
    # @param type_str [String] The type string
    # @return [String] The sorted type string
    def self.sort_top_level_union(type_str)
      return type_str unless type_str.include?("|")

      parts = split_union_members(type_str)
      return type_str if parts.size <= 1

      # Separate null from other types
      regular_parts, null_parts = parts.partition { |p| p.strip.downcase != "null" }

      sorted_regular = regular_parts.sort_by { |p| p.strip.downcase }
      (sorted_regular + null_parts).join(" | ")
    end

    # Splits union members while respecting nested brackets
    # @param str [String] The string to split
    # @return [Array<String>] Array of union members
    def self.split_union_members(str)
      members = []
      current = +""
      depth = 0

      str.each_char do |char|
        case char
        when "<", "("
          depth += 1
          current << char
        when ">", ")"
          depth -= 1
          current << char
        when "|"
          if depth == 0
            members << current.strip unless current.strip.empty?
            current = +""
          else
            current << char
          end
        else
          current << char
        end
      end

      members << current.strip unless current.strip.empty?
      members
    end

    # Checks if brackets are balanced in the string
    # @param str [String] The string to check
    # @return [Boolean] True if brackets are balanced
    def self.balanced_brackets?(str)
      angle_depth = 0
      paren_depth = 0

      str.each_char do |char|
        case char
        when "<"
          angle_depth += 1
        when ">"
          angle_depth -= 1
          return false if angle_depth < 0
        when "("
          paren_depth += 1
        when ")"
          paren_depth -= 1
          return false if paren_depth < 0
        end
      end

      angle_depth == 0 && paren_depth == 0
    end
  end
end
