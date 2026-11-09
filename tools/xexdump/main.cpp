// xexdump: load an XEX2 with XenonUtils (decrypt + decompress) and dump the
// flat memory image plus a section map, so it can be searched/disassembled.
#include <cstdio>
#include <fstream>
#include <vector>
#include <image.h>
#include <file.h>

int main(int argc, char** argv)
{
    if (argc < 3)
    {
        std::printf("usage: xexdump <in.xex> <out.bin>\n");
        return 1;
    }

    std::ifstream in(argv[1], std::ios::binary);
    std::vector<uint8_t> file((std::istreambuf_iterator<char>(in)), {});
    Image image = Image::ParseImage(file.data(), file.size());
    if (!image.data)
    {
        std::printf("failed to load %s\n", argv[1]);
        return 1;
    }

    std::ofstream out(argv[2], std::ios::binary);
    out.write(reinterpret_cast<const char*>(image.data.get()), image.size);

    std::printf("base=0x%zX size=0x%X entry=0x%zX\n", image.base, image.size, image.entry_point);
    for (const auto& s : image.sections)
        std::printf("section %-10s 0x%08zX-0x%08zX %s\n", s.name.c_str(), s.base, s.base + s.size,
            (s.flags & SectionFlags_Code) ? "code" : "data");

    // Import thunks, one per line, for scripts: "import 0xADDR name"
    if (argc > 3)
    {
        std::ofstream imp(argv[3]);
        for (const auto& sym : image.symbols)
            if (sym.type == Symbol_Function)
                imp << "0x" << std::hex << sym.address << " " << sym.name << "\n";
    }
    return 0;
}
