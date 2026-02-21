CXX ?= c++
CXXFLAGS ?= -O2 -Wall -Wextra -std=c++20

PKG_CFLAGS := $(shell pkg-config --cflags wayland-client libpng)
PKG_LIBS := $(shell pkg-config --libs wayland-client libpng)

HYPRWAYLAND_SCANNER ?= hyprwayland-scanner
PROTOCOL_XML ?= /usr/share/hyprland-protocols/protocols/hyprland-toplevel-export-v1.xml
FOREIGN_XML ?= /home/_WD_/Dev/Hyprland/protocols/wlr-foreign-toplevel-management-unstable-v1.xml

GEN_HEADER := hyprland-toplevel-export-v1.hpp
GEN_SOURCE := hyprland-toplevel-export-v1.cpp
FOREIGN_HEADER := wlr-foreign-toplevel-management-unstable-v1.hpp
FOREIGN_SOURCE := wlr-foreign-toplevel-management-unstable-v1.cpp
TARGET := hyprland-toplevel-snap

.PHONY: all clean regen

all: $(TARGET)

$(TARGET): hyprland-toplevel-snap.cpp $(GEN_SOURCE) $(GEN_HEADER) $(FOREIGN_SOURCE) $(FOREIGN_HEADER)
	$(CXX) $(CXXFLAGS) $(PKG_CFLAGS) -o $@ hyprland-toplevel-snap.cpp $(GEN_SOURCE) $(FOREIGN_SOURCE) $(PKG_LIBS)

regen: $(GEN_SOURCE) $(GEN_HEADER) $(FOREIGN_SOURCE) $(FOREIGN_HEADER)

$(GEN_HEADER): $(PROTOCOL_XML)
	$(HYPRWAYLAND_SCANNER) --client $< .

$(GEN_SOURCE): $(PROTOCOL_XML)
	$(HYPRWAYLAND_SCANNER) --client $< .

$(FOREIGN_HEADER): $(FOREIGN_XML)
	$(HYPRWAYLAND_SCANNER) --client $< .

$(FOREIGN_SOURCE): $(FOREIGN_XML)
	$(HYPRWAYLAND_SCANNER) --client $< .

clean:
	rm -f $(TARGET) $(GEN_HEADER) $(GEN_SOURCE) $(FOREIGN_HEADER) $(FOREIGN_SOURCE)
