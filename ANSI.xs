#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include <windows.h>
#include <ImageHlp.h>
#include <tlhelp32.h>

// ========== Auxiliary debug function

#define MYDEBUG 0

#if (MYDEBUG > 0)
void DEBUGSTR( char * szFormat, ...) {  // sort of OutputDebugStringf
  char szBuffer[1024];
  va_list pArgList;
  va_start(pArgList, szFormat);
  _vsnprintf(szBuffer, sizeof(szBuffer), szFormat, pArgList);
  va_end(pArgList);
  OutputDebugString(szBuffer);
}
#else
#define DEBUGSTR //DEBUGSTR
#endif

// ========== Global variables and constants

// Macro for adding pointers/DWORDs together without C arithmetic interfering
#define MakePtr( cast, ptr, addValue ) (cast)( (DWORD)(ptr)+(DWORD)(addValue))

HINSTANCE hDllInstance;       // Dll instance handle
HANDLE hConOut;               // handle to CONOUT$
BOOL bIsWin9x;

#define ESC     '\x1B'        // ESCape character
#define LF      '\x0A'        // Line Feed

#define MAX_TITLE_SIZE 1024   // max title string console size

#define MAX_ARG 16            // max number of args in an escape sequence
int state;                    // automata state
char prefix;                  // escape sequence prefix ( '[' or '(' );
char suffix;                  // escape sequence suffix
int es_argc;                  // escape sequence args count
int es_argv[MAX_ARG];         // escape sequence args

// color constants

#define FOREGROUND_BLACK 0
#define FOREGROUND_WHITE FOREGROUND_RED|FOREGROUND_GREEN|FOREGROUND_BLUE

#define BACKGROUND_BLACK 0
#define BACKGROUND_WHITE BACKGROUND_RED|BACKGROUND_GREEN|BACKGROUND_BLUE

WORD foregroundcolor[8] = {
  FOREGROUND_BLACK,                                 // black foreground
  FOREGROUND_RED,                                   // red foreground
  FOREGROUND_GREEN,                                 // green foreground
  FOREGROUND_RED|FOREGROUND_GREEN,                  // yellow foreground
  FOREGROUND_BLUE,                                  // blue foreground
  FOREGROUND_BLUE|FOREGROUND_RED,                   // magenta foreground
  FOREGROUND_BLUE|FOREGROUND_GREEN,                 // cyan foreground
  FOREGROUND_WHITE                                  // white foreground
};

WORD backgroundcolor[8] = {
  BACKGROUND_BLACK,                                 // black background
  BACKGROUND_RED,                                   // red background
  BACKGROUND_GREEN,                                 // green background
  BACKGROUND_RED|BACKGROUND_GREEN,                  // yellow background
  BACKGROUND_BLUE,                                  // blue background
  BACKGROUND_BLUE|BACKGROUND_RED,                   // magenta background
  BACKGROUND_BLUE|BACKGROUND_GREEN,                 // cyan background
  BACKGROUND_WHITE,                                 // white background
};

// screen attributes
WORD foreground = FOREGROUND_WHITE;
WORD background = BACKGROUND_BLACK;
WORD bold       = 0;
WORD underline  = 0;
WORD rvideo     = 0;
WORD concealed  = 0;
WORD conversion_enabled = 1;  // enabled by default ANSI(Win) --> OEM(Dos)
UINT Cp_In  = CP_ACP;         // default script codepage (ANSI)
UINT Cp_Out = CP_OEMCP;       // default ouput codepage  (OEM)
UINT SaveCP;

// saved cursor position
COORD SavePos = {0, 0};



// ========== Hooking API functions
//
// References about API hooking (and dll injection):
// - Matt Pietrek ~ Windows 95 System Programming Secrets.
// - Jeffrey Richter ~ Programming Applications for Microsoft Windows 4th ed.

//-----------------------------------------------------------------------------
//   HookAPIOneMod
// Substitute a new function in the Import Address Table (IAT) of the
// specified module .
// Return FALSE on error and TRUE on success.
//-----------------------------------------------------------------------------

BOOL HookAPIOneMod(
    HMODULE hFromModule,        // Handle of the module to intercept calls from
    PSTR    pszFunctionModule,  // Name of the module to intercept calls to
    PSTR    pszOldFunctionName, // Name of the function to intercept calls to
    PROC    pfnNewFunction      // New function (replaces old one)
    )
{
  PROC                      pfnOldFunction;
  PIMAGE_DOS_HEADER         pDosHeader;
  PIMAGE_NT_HEADERS         pNTHeader;
  PIMAGE_IMPORT_DESCRIPTOR  pImportDesc;
  PIMAGE_THUNK_DATA         pThunk;

  // Verify that a valid pfn was passed
  if ( IsBadCodePtr(pfnNewFunction) ) {
    DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
    return FALSE;
  }

  // Verify that the module and function names passed are valid
  pfnOldFunction = GetProcAddress( GetModuleHandle(pszFunctionModule),
                                   pszOldFunctionName );
  if ( !pfnOldFunction )
  {
    DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
    return FALSE;
  }

  // Tests to make sure we're looking at a module image (the 'MZ' header)
  pDosHeader = (PIMAGE_DOS_HEADER)hFromModule;
  if ( IsBadReadPtr(pDosHeader, sizeof(IMAGE_DOS_HEADER)) ) {
    DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
    return FALSE;
  }
  if ( pDosHeader->e_magic != IMAGE_DOS_SIGNATURE ) {
    DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
    return FALSE;
  }

  // The MZ header has a pointer to the PE header
  pNTHeader = MakePtr(PIMAGE_NT_HEADERS, pDosHeader, pDosHeader->e_lfanew);

  // More tests to make sure we're looking at a "PE" image
  if ( IsBadReadPtr(pNTHeader, sizeof(IMAGE_NT_HEADERS)) ) {
    DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
    return FALSE;
  }
  if ( pNTHeader->Signature != IMAGE_NT_SIGNATURE ) {
    DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
    return FALSE;
  }

  // We know have a valid pointer to the module's PE header.
  // Get a pointer to its imports section
  pImportDesc = MakePtr(PIMAGE_IMPORT_DESCRIPTOR,
                        pDosHeader,
                        pNTHeader->OptionalHeader.
                          DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].
                          VirtualAddress);

  // Bail out if the RVA of the imports section is 0 (it doesn't exist)
  if ( pImportDesc == (PIMAGE_IMPORT_DESCRIPTOR)pNTHeader ) {
    return TRUE;
  }

  // Iterate through the array of imported module descriptors, looking
  // for the module whose name matches the pszFunctionModule parameter
  while ( pImportDesc->Name ) {
    PSTR pszModName = MakePtr(PSTR, pDosHeader, pImportDesc->Name);
    if ( stricmp(pszModName, pszFunctionModule) == 0 )
      break;
    pImportDesc++;  // Advance to next imported module descriptor
  }

  // Bail out if we didn't find the import module descriptor for the
  // specified module.  pImportDesc->Name will be non-zero if we found it.
  if ( pImportDesc->Name == 0 )
    return TRUE;

  // Get a pointer to the found module's import address table (IAT)
  pThunk = MakePtr(PIMAGE_THUNK_DATA, pDosHeader, pImportDesc->FirstThunk);

  // Blast through the table of import addresses, looking for the one
  // that matches the address we got back from GetProcAddress above.
  while ( pThunk->u1.Function ) {
         // double cast avoid warning with VC6 and VC7 :-)
    if ( (DWORD) pThunk->u1.Function == (DWORD)pfnOldFunction ) { // We found it!
      DWORD flOldProtect, flNewProtect, flDummy;
      MEMORY_BASIC_INFORMATION mbi;

      // Get the current protection attributes
      VirtualQuery(&pThunk->u1.Function, &mbi, sizeof(mbi));
      // Take the access protection flags
      flNewProtect = mbi.Protect;
      // Remove ReadOnly and ExecuteRead flags
      flNewProtect &= ~(PAGE_READONLY | PAGE_EXECUTE_READ);
      // Add on ReadWrite flag
      flNewProtect |= (PAGE_READWRITE);
      // Change the access protection on the region of committed pages in the
      // virtual address space of the current process
      VirtualProtect(&pThunk->u1.Function, sizeof(PVOID), flNewProtect, &flOldProtect );

      // Overwrite the original address with the address of the new function
      if ( !WriteProcessMemory(GetCurrentProcess(),
                               &pThunk->u1.Function,
                               &pfnNewFunction,
                               sizeof(pfnNewFunction), NULL) ) {
        DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
        return FALSE;
      }

      // Put the page attributes back the way they were.
      VirtualProtect( &pThunk->u1.Function, sizeof(PVOID), flOldProtect, &flDummy);
      return TRUE;
    }
    pThunk++;     // Advance to next imported function address
  }
  return TRUE;    // Function not found
}

//-----------------------------------------------------------------------------
//   HookAPIAllMod
// Substitute a new function in the Import Address Table (IAT) of all
// the modules in the current process.
// Return FALSE on error and TRUE on success.
//-----------------------------------------------------------------------------

BOOL HookAPIAllMod(
    PSTR    pszFunctionModule,      // Module to intercept calls to
    PSTR    pszOldFunctionName,     // Function to intercept calls to
    PROC    pfnNewFunction          // New function (replaces old function)
    )
{
  HANDLE          hModuleSnap = NULL;
  MODULEENTRY32   me        = {0};
  BOOL fOk;

  // Take a snapshot of all modules in the current process.
  hModuleSnap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());

  if (hModuleSnap == (HANDLE)-1) {
    DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
    return FALSE;
  }

  // Fill the size of the structure before using it.
  me.dwSize = sizeof(MODULEENTRY32);

  // Walk the module list of the modules
  for (fOk = Module32First(hModuleSnap, &me); fOk; fOk = Module32Next(hModuleSnap, &me) ) {
    // We don't hook functions in our own module
    if (me.hModule != hDllInstance) {
      DEBUGSTR("Hooking in %s", me.szModule);
      // Hook this function in this module
      if (!HookAPIOneMod(me.hModule, pszFunctionModule, pszOldFunctionName, pfnNewFunction) ) {
        CloseHandle (hModuleSnap);
        DEBUGSTR("error: %s(%d)", __FILE__, __LINE__);
        return FALSE;
      }
    }
  }
  CloseHandle (hModuleSnap);
  return TRUE;
}

// ========== Print Buffer functions

#define BUFFER_SIZE 256

int nCharInBuffer = 0;
char  ChBuffer[BUFFER_SIZE];
WCHAR WcBuffer[BUFFER_SIZE];

//-----------------------------------------------------------------------------
//   FlushBuffer()
// Converts the buffer from ANSI to OEM and write it in the console.
//-----------------------------------------------------------------------------

void FlushBuffer( )
{
  DWORD nWritten;
  if (nCharInBuffer <= 0) return;
  if ( conversion_enabled ) {
    MultiByteToWideChar(Cp_In, 0, ChBuffer, nCharInBuffer, WcBuffer, BUFFER_SIZE);
    WideCharToMultiByte(Cp_Out, 0, WcBuffer, nCharInBuffer, ChBuffer, BUFFER_SIZE, NULL, NULL);
  }
  WriteConsole(hConOut, ChBuffer, nCharInBuffer, &nWritten, NULL);
  nCharInBuffer = 0;
}

//-----------------------------------------------------------------------------
//   PushBuffer( char c)
// Adds a character in the buffer and flushes the buffer if it is full
//-----------------------------------------------------------------------------

void PushBuffer( char c)
{
  ChBuffer[nCharInBuffer++] = concealed ? ' ' : c;
  if (nCharInBuffer >= BUFFER_SIZE) {
    FlushBuffer();
    DEBUGSTR("flush");
  }
}

// ========== Print functions

//-----------------------------------------------------------------------------
//   InterpretEscSeq( )
// Interprets the last escape sequence scanned by ParseAndPrintString
//   prefix             escape sequence prefix
//   es_argc            escape sequence args count
//   es_argv[]          escape sequence args array
//   suffix             escape sequence suffix
//
// for instance, with \e[33;45;1m we have
// prefix = '[',
// es_argc = 3, es_argv[0] = 33, es_argv[1] = 45, es_argv[2] = 1
// suffix = 'm'
//-----------------------------------------------------------------------------

void InterpretEscSeq( )
{
  int i;
  WORD attribut;
  CONSOLE_SCREEN_BUFFER_INFO Info;
  DWORD NumberOfCharsWritten;
  COORD Pos;
  SMALL_RECT Rect;
  CHAR_INFO CharInfo;

  if (prefix == '[') {
    GetConsoleScreenBufferInfo(hConOut, &Info);
    switch (suffix) {
      case 'm':
        if ( es_argc == 0 ) es_argv[es_argc++] = 0;
        for(i=0; i<es_argc; i++) {
          switch (es_argv[i]) {
            case 0 :
              foreground = FOREGROUND_WHITE;
              background = BACKGROUND_BLACK;
              bold = 0;
              underline = 0;
              rvideo = 0;
              concealed = 0;
              break;
            case 1 :
              bold = 1;
              break;
            case 21 :
              bold = 0;
              break;
            case 4 :
              underline = 1;
              break;
            case 24 :
              underline = 0;
              break;
            case 7 :
              rvideo = 1;
              break;
            case 27 :
              rvideo = 0;
              break;
            case 8 :
              concealed = 1;
              break;
            case 28 :
              concealed = 0;
              break;
          }
          if ( (30 <= es_argv[i]) && (es_argv[i] <= 37) ) foreground = es_argv[i]-30;
          if ( (40 <= es_argv[i]) && (es_argv[i] <= 47) ) background = es_argv[i]-40;
        }
        if (rvideo) attribut = foregroundcolor[background] | backgroundcolor[foreground];
        else attribut = foregroundcolor[foreground] | backgroundcolor[background];
        if (bold) attribut |= FOREGROUND_INTENSITY;
        if (underline) attribut |= BACKGROUND_INTENSITY;
        SetConsoleTextAttribute(hConOut, attribut);
        return;

      case 'J':
        if ( es_argc == 0 ) es_argv[es_argc++] = 0;   // ESC[J == ESC[0J
        if ( es_argc != 1 ) return;
        switch (es_argv[0]) {
          case 0 :              // ESC[0J erase from cursor to end of display
            FillConsoleOutputCharacter(
              hConOut,
              ' ',
              (Info.dwSize.Y-Info.dwCursorPosition.Y-1)
                  *Info.dwSize.X+Info.dwSize.X-Info.dwCursorPosition.X-1,
              Info.dwCursorPosition,
              &NumberOfCharsWritten);

            FillConsoleOutputAttribute(
              hConOut,
              Info.wAttributes,
              (Info.dwSize.Y-Info.dwCursorPosition.Y-1)
                  *Info.dwSize.X+Info.dwSize.X-Info.dwCursorPosition.X-1,
              Info.dwCursorPosition,
              &NumberOfCharsWritten);
            return;

          case 1 :              // ESC[1J erase from start to cursor.
            Pos.X = 0;
            Pos.Y = 0;
            FillConsoleOutputCharacter(
              hConOut,
              ' ',
              Info.dwCursorPosition.Y*Info.dwSize.X+Info.dwCursorPosition.X+1,
              Pos,
              &NumberOfCharsWritten);

            FillConsoleOutputAttribute(
              hConOut,
              Info.wAttributes,
              Info.dwCursorPosition.Y*Info.dwSize.X+Info.dwCursorPosition.X+1,
              Pos,
              &NumberOfCharsWritten);
            return;

          case 2 :              // ESC[2J Clear screen and home cursor
            Pos.X = 0;
            Pos.Y = 0;
            FillConsoleOutputCharacter(
              hConOut,
              ' ',
              Info.dwSize.X*Info.dwSize.Y,
              Pos,
              &NumberOfCharsWritten);
            FillConsoleOutputAttribute(
              hConOut,
              Info.wAttributes,
              Info.dwSize.X*Info.dwSize.Y,
              Pos,
              &NumberOfCharsWritten);
            SetConsoleCursorPosition(hConOut, Pos);
            return;

          default :
            return;
        }

      case 'K' :
        if ( es_argc == 0 ) es_argv[es_argc++] = 0;   // ESC[K == ESC[0K
        if ( es_argc != 1 ) return;
        switch (es_argv[0]) {
          case 0 :              // ESC[0K Clear to end of line
            FillConsoleOutputCharacter(
              hConOut,
              ' ',
              Info.srWindow.Right-Info.dwCursorPosition.X+1,
              Info.dwCursorPosition,
              &NumberOfCharsWritten);

            FillConsoleOutputAttribute(
              hConOut,
              Info.wAttributes,
              Info.srWindow.Right-Info.dwCursorPosition.X+1,
              Info.dwCursorPosition,
              &NumberOfCharsWritten);
            return;

          case 1 :              // ESC[1K Clear from start of line to cursor
            Pos.X = 0;
            Pos.Y = Info.dwCursorPosition.Y;
            FillConsoleOutputCharacter(
              hConOut,
              ' ',
              Info.dwCursorPosition.X+1,
              Pos,
              &NumberOfCharsWritten);

            FillConsoleOutputAttribute(
              hConOut,
              Info.wAttributes,
              Info.dwCursorPosition.X+1,
              Pos,
              &NumberOfCharsWritten);
            return;

          case 2 :              // ESC[2K Clear whole line.
            Pos.X = 0;
            Pos.Y = Info.dwCursorPosition.Y;
            FillConsoleOutputCharacter(
              hConOut,
              ' ',
              Info.dwSize.X,
              Pos,
              &NumberOfCharsWritten);
            FillConsoleOutputAttribute(
              hConOut,
              Info.wAttributes,
              Info.dwSize.X,
              Pos,
              &NumberOfCharsWritten);
            return;

          default :
            return;
        }

      case 'L' :                                    // ESC[#L Insert # blank lines.
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[L == ESC[1L
        if ( es_argc != 1 ) return;
        Rect.Left   = 0;
        Rect.Top    = Info.dwCursorPosition.Y;
        Rect.Right  = Info.dwSize.X-1;
        Rect.Bottom = Info.dwSize.Y-1;
        Pos.X = 0;
        Pos.Y = Info.dwCursorPosition.Y+es_argv[0];
        CharInfo.Char.AsciiChar = ' ';
        CharInfo.Attributes = Info.wAttributes;
        ScrollConsoleScreenBuffer(
          hConOut,
          &Rect,
          NULL,
          Pos,
          &CharInfo);
        Pos.X = 0;
        Pos.Y = Info.dwCursorPosition.Y;
        FillConsoleOutputCharacter(
          hConOut,
          ' ',
          Info.dwSize.X*es_argv[0],
          Pos,
          &NumberOfCharsWritten);
        FillConsoleOutputAttribute(
          hConOut,
          Info.wAttributes,
          Info.dwSize.X*es_argv[0],
          Pos,
          &NumberOfCharsWritten);
        return;

      case 'M' :                                      // ESC[#M Delete # line.
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[M == ESC[1M
        if ( es_argc != 1 ) return;
        if ( es_argv[0] > Info.dwSize.Y - Info.dwCursorPosition.Y )
          es_argv[0] = Info.dwSize.Y - Info.dwCursorPosition.Y;
        Rect.Left   = 0;
        Rect.Top    = Info.dwCursorPosition.Y+es_argv[0];
        Rect.Right  = Info.dwSize.X-1;
        Rect.Bottom = Info.dwSize.Y-1;
        Pos.X = 0;
        Pos.Y = Info.dwCursorPosition.Y;
        CharInfo.Char.AsciiChar = ' ';
        CharInfo.Attributes = Info.wAttributes;
        ScrollConsoleScreenBuffer(
          hConOut,
          &Rect,
          NULL,
          Pos,
          &CharInfo);
        Pos.Y = Info.dwSize.Y - es_argv[0];
        FillConsoleOutputCharacter(
          hConOut,
          ' ',
          Info.dwSize.X * es_argv[0],
          Pos,
          &NumberOfCharsWritten);
        FillConsoleOutputAttribute(
          hConOut,
          Info.wAttributes,
          Info.dwSize.X * es_argv[0],
          Pos,
          &NumberOfCharsWritten);
        return;

      case 'P' :                                      // ESC[#P Delete # characters.
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[P == ESC[1P
        if ( es_argc != 1 ) return;
        if (Info.dwCursorPosition.X + es_argv[0] > Info.dwSize.X - 1)
              es_argv[0] = Info.dwSize.X - Info.dwCursorPosition.X;

        Rect.Left   = Info.dwCursorPosition.X + es_argv[0];
        Rect.Top    = Info.dwCursorPosition.Y;
        Rect.Right  = Info.dwSize.X-1;
        Rect.Bottom = Info.dwCursorPosition.Y;
        CharInfo.Char.AsciiChar = ' ';
        CharInfo.Attributes = Info.wAttributes;
        ScrollConsoleScreenBuffer(
          hConOut,
          &Rect,
          NULL,
          Info.dwCursorPosition,
          &CharInfo);
        Pos.X = Info.dwSize.X - es_argv[0];
        Pos.Y = Info.dwCursorPosition.Y;
        FillConsoleOutputCharacter(
          hConOut,
          ' ',
          es_argv[0],
          Pos,
          &NumberOfCharsWritten);
        return;

      case '@' :                                      // ESC[#@ Insert # blank characters.
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[@ == ESC[1@
        if ( es_argc != 1 ) return;
        if (Info.dwCursorPosition.X + es_argv[0] > Info.dwSize.X - 1)
          es_argv[0] = Info.dwSize.X - Info.dwCursorPosition.X;
        Rect.Left   = Info.dwCursorPosition.X;
        Rect.Top    = Info.dwCursorPosition.Y;
        Rect.Right  = Info.dwSize.X-1-es_argv[0];
        Rect.Bottom = Info.dwCursorPosition.Y;
        Pos.X = Info.dwCursorPosition.X+es_argv[0];
        Pos.Y = Info.dwCursorPosition.Y;
        CharInfo.Char.AsciiChar = ' ';
        CharInfo.Attributes = Info.wAttributes;
        ScrollConsoleScreenBuffer(
          hConOut,
          &Rect,
          NULL,
          Pos,
          &CharInfo);
        FillConsoleOutputCharacter(
          hConOut,
          ' ',
          es_argv[0],
          Info.dwCursorPosition,
          &NumberOfCharsWritten);
        FillConsoleOutputAttribute(
          hConOut,
          Info.wAttributes,
          es_argv[0],
          Info.dwCursorPosition,
          &NumberOfCharsWritten);
        return;

      case 'A' :                                      // ESC[#A Moves cursor up # lines
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[A == ESC[1A
        if ( es_argc != 1 ) return;
        Pos.X = Info.dwCursorPosition.X;
        Pos.Y = Info.dwCursorPosition.Y-es_argv[0];
        if (Pos.Y < 0) Pos.Y = 0;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 'B' :                                      // ESC[#B Moves cursor down # lines
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[B == ESC[1B
        if ( es_argc != 1 ) return;
        Pos.X = Info.dwCursorPosition.X;
        Pos.Y = Info.dwCursorPosition.Y+es_argv[0];
        if (Pos.Y >= Info.dwSize.Y) Pos.Y = Info.dwSize.Y-1;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 'C' :                                      // ESC[#C Moves cursor forward # spaces
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[C == ESC[1C
        if ( es_argc != 1 ) return;
        Pos.X = Info.dwCursorPosition.X+es_argv[0];
        if ( Pos.X >= Info.dwSize.X ) Pos.X = Info.dwSize.X-1;
        Pos.Y = Info.dwCursorPosition.Y;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 'D' :                                      // ESC[#D Moves cursor back # spaces
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[D == ESC[1D
        if ( es_argc != 1 ) return;
        Pos.X = Info.dwCursorPosition.X-es_argv[0];
        if ( Pos.X < 0 ) Pos.X = 0;
        Pos.Y = Info.dwCursorPosition.Y;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 'E' :                               // ESC[#E Moves cursor down # lines, column 1.
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[E == ESC[1E
        if ( es_argc != 1 ) return;
        Pos.X = 0;
        Pos.Y = Info.dwCursorPosition.Y+es_argv[0];
        if (Pos.Y >= Info.dwSize.Y) Pos.Y = Info.dwSize.Y-1;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 'F' :                               // ESC[#F Moves cursor up # lines, column 1.
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[F == ESC[1F
        if ( es_argc != 1 ) return;
        Pos.X = 0;
        Pos.Y = Info.dwCursorPosition.Y-es_argv[0];
        if ( Pos.Y < 0 ) Pos.Y = 0;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 'G' :                               // ESC[#G Moves cursor column # in current row.
        if ( es_argc == 0 ) es_argv[es_argc++] = 1;   // ESC[G == ESC[1G
        if ( es_argc != 1 ) return;
        Pos.X = es_argv[0] - 1;
        if ( Pos.X >= Info.dwSize.X ) Pos.X = Info.dwSize.X-1;
        if ( Pos.X < 0) Pos.X = 0;
        Pos.Y = Info.dwCursorPosition.Y;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 'f' :
      case 'H' :                               // ESC[#;#H or ESC[#;#f Moves cursor to line #, column #
        if ( es_argc == 0 ) {
          es_argv[es_argc++] = 1;   // ESC[G == ESC[1;1G
          es_argv[es_argc++] = 1;
        }
        if ( es_argc == 1 ) {
          es_argv[es_argc++] = 1;   // ESC[nG == ESC[n;1G
        }
        if ( es_argc > 2 ) return;
        Pos.X = es_argv[1] - 1;
        if ( Pos.X < 0) Pos.X = 0;
        if ( Pos.X >= Info.dwSize.X ) Pos.X = Info.dwSize.X-1;
        Pos.Y = es_argv[0] - 1;
        if ( Pos.Y < 0) Pos.Y = 0;
        if (Pos.Y >= Info.dwSize.Y) Pos.Y = Info.dwSize.Y-1;
        SetConsoleCursorPosition(hConOut, Pos);
        return;

      case 's' :                               // ESC[s Saves cursor position for recall later
        if ( es_argc != 0 ) return;
        SavePos.X = Info.dwCursorPosition.X;
        SavePos.Y = Info.dwCursorPosition.Y;
        return;

      case 'u' :                               // ESC[u Return to saved cursor position
        if ( es_argc != 0 ) return;
        SetConsoleCursorPosition(hConOut, SavePos);
        return;

      default :
        return;

    }
  }
  else if (prefix == '(') {
    switch (suffix) {
      case 'U' :                                // ESC(U no mapping
        if ( es_argc != 0 ) return;
        FlushBuffer();
        conversion_enabled = 0;
        return;

      case 'K' :                                // ESC(K mapping if it exist
        if ( es_argc != 0 ) return;
        FlushBuffer();
        SetConsoleOutputCP(SaveCP);
        Cp_Out = CP_OEMCP;
        conversion_enabled = 1;
        return;

      case 'X' :                                // ESC(#X codepage **EXPERIMENTAL**
        if ( es_argc != 1 ) return;
        FlushBuffer();
        SetConsoleOutputCP(es_argv[0]);
        conversion_enabled = 0;
        return;
    }
  }
  else {

  }
}

HANDLE hCurrentDev = 0;     // handle to the current device

//-----------------------------------------------------------------------------
//   ParseAndPrintString(hDev, lpBuffer, nNumberOfBytesToWrite)
// Parses the string lpBuffer, interprets the escapes sequences and prints the
// characters in the device hDev (console).
// The lexer is a four states automata.
// If the number of arguments es_argc > MAX_ARG, only the MAX_ARG-1 firsts and
// the last arguments are processed (no es_argv[] overflow).
//-----------------------------------------------------------------------------

BOOL
ParseAndPrintString(HANDLE hDev,
                    LPCVOID lpBuffer,
                    DWORD nNumberOfBytesToWrite,
                    LPDWORD lpNumberOfBytesWritten
                    )
{
  DWORD i;
  char * s;

  if (hDev != hCurrentDev) {
    hCurrentDev = hDev;
    state = 1;            // reinit if device have changed
  }
  for(i=nNumberOfBytesToWrite, s=(char *)lpBuffer; i>0; i--, s++) {
    if (state==1) {
      // Under Win9x, at each new line, the console fills the end of the line with
      // the default attribute. We correct this behavior here.
      if ( bIsWin9x && (*s == LF) ) {
        CONSOLE_SCREEN_BUFFER_INFO Info;
        COORD Pos = {0, 0};
        SMALL_RECT Rect;
        CHAR_INFO CharInfo;

        FlushBuffer();
        GetConsoleScreenBufferInfo(hConOut, &Info);
        Info.dwCursorPosition.Y++;
        if ( Info.dwCursorPosition.Y < Info.dwSize.Y ){
          Info.dwCursorPosition.X = 0;
          SetConsoleCursorPosition(hConOut, Info.dwCursorPosition);
        }
        else {
          Rect.Left   = 0;
          Rect.Top    = 1;
          Rect.Right  = Info.dwSize.X-1;
          Rect.Bottom = Info.dwSize.Y-1;
          CharInfo.Char.AsciiChar = ' ';
          CharInfo.Attributes = Info.wAttributes;
          ScrollConsoleScreenBuffer(
            hConOut,
            &Rect,
            NULL,
            Pos,
            &CharInfo);
          Pos.Y = Info.dwSize.Y-1;
          SetConsoleCursorPosition(hConOut, Pos);
        }
      }
      else if (*s == ESC) state = 2;
      else PushBuffer(*s);
    }
    else if (state == 2) {
      if (*s == ESC);       // \e\e...\e == \e
      else if ( (*s == '[') || (*s == '(') ) {
        FlushBuffer();
        prefix = *s;
        state = 3;
      }
      else state = 1;
    }
    else if (state == 3) {
      if ( isdigit(*s)) {
        es_argc = 0;
        es_argv[0] = *s-'0';
        state = 4;
      }
      else if ( *s == ';' ) {
        es_argc = 1;
        es_argv[0] = 0;
        es_argv[es_argc] = 0;
        state = 4;
      }
      else {
        es_argc = 0;
        suffix = *s;
        InterpretEscSeq();
        state = 1;
      }
    }
    else if (state == 4) {
      if ( isdigit(*s)) {
        es_argv[es_argc] = 10*es_argv[es_argc]+(*s-'0');
      }
      else if ( *s == ';' ) {
        if (es_argc < MAX_ARG-1) es_argc++;
        es_argv[es_argc] = 0;
      }
      else {
        if (es_argc < MAX_ARG-1) es_argc++;
        suffix = *s;
        InterpretEscSeq();
        state = 1;
      }
    }

    else { // error: unknown automata state
      exit (1);
    }
  }
  FlushBuffer();
  *lpNumberOfBytesWritten = nNumberOfBytesToWrite - i;
  return (i == 0);
}

//-----------------------------------------------------------------------------
//   MyWriteFile
// It is the new function that must replace the original WriteFile function.
// This function have exactly the same signature as the original one.
//-----------------------------------------------------------------------------

BOOL
WINAPI MyWriteFile(HANDLE hFile, LPCVOID lpBuffer, DWORD nNumberOfBytesToWrite,
            LPDWORD lpNumberOfBytesWritten, LPOVERLAPPED lpOverlapped)
{
  DWORD DummyMode;
  if( GetConsoleMode(hFile, &DummyMode) ) {  // if we write in a console buffer
    return ParseAndPrintString(hFile,
                               lpBuffer,
                               nNumberOfBytesToWrite,
                               lpNumberOfBytesWritten);
  }
  else      // here, WriteFile is the old function (this module is not hooked)
    return WriteFile(hFile, lpBuffer,
                     nNumberOfBytesToWrite,
                     lpNumberOfBytesWritten,
                     lpOverlapped );
}

// ========== Initialisation

//-----------------------------------------------------------------------------
//   DllMain()
// Function called by the system when processes and threads are initialized
// and terminated.
//-----------------------------------------------------------------------------

BOOL WINAPI DllMain(HINSTANCE hInstance, DWORD dwReason, LPVOID lpReserved)
{
	BOOL bResult = TRUE;
	switch( dwReason )
	{
		case DLL_PROCESS_ATTACH:
		  hDllInstance = hInstance;  // save Dll instance handle
		  DEBUGSTR("hDllInstance = 0x%.8x", hDllInstance);
      hConOut = CreateFile(
        "CONOUT$",
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL,
        OPEN_EXISTING,
        0,
        NULL);
		  DEBUGSTR("hConOut = 0x%.8x", hConOut);
		  bIsWin9x = (win32_os_id() != VER_PLATFORM_WIN32_NT);
		  DEBUGSTR("bIsWin9x = %d", bIsWin9x);
		  SaveCP = GetConsoleOutputCP();
		  Cp_Out = SaveCP;
		  Cp_In  = GetACP();
		  bResult = HookAPIAllMod("KERNEL32.dll", "WriteFile", (PROC)MyWriteFile);
			break;

		case DLL_PROCESS_DETACH:
      break;
	}
  return (bResult);
}

// ========== Auxiliary functions

MODULE = Win32::Console::ANSI		PACKAGE = Win32::Console::ANSI
  
PROTOTYPES: ENABLE

# ---------------------------------------------------------
#    Cls()
#  Clears the screen with the current background color, and
#  set cursor to (1,1).
# ---------------------------------------------------------

void
Cls()
  CODE:
    CONSOLE_SCREEN_BUFFER_INFO Info;
    DWORD NumberOfCharsWritten;
    COORD Pos;
    Pos.X = 0;
    Pos.Y = 0;
    GetConsoleScreenBufferInfo(hConOut, &Info);
    FillConsoleOutputCharacter(
      hConOut,
      ' ',
      Info.dwSize.X*Info.dwSize.Y,
      Pos,
      &NumberOfCharsWritten);
    FillConsoleOutputAttribute(
      hConOut,
      Info.wAttributes,
      Info.dwSize.X*Info.dwSize.Y,
      Pos,
      &NumberOfCharsWritten);
    SetConsoleCursorPosition(hConOut, Pos);


# ---------------------------------------------------------
# ($old_x, $old_y) = Cursor( [$new_x, $new_y] );
#   Gets and sets the cursor position.
# ---------------------------------------------------------

void
Cursor( ... )
  PREINIT:
    CONSOLE_SCREEN_BUFFER_INFO Info;
    COORD dwNewCurPos;
    short x = 0;
    short y = 0;
  PPCODE:
    if ( (items == 1) || (items > 2) )
      croak("Usage: Cursor( [col, line] )");
    GetConsoleScreenBufferInfo(hConOut, &Info);
    if ( items == 2 ) {
      x = (short) SvIV(ST(0));
      y = (short) SvIV(ST(1));
      dwNewCurPos.X = x - 1;
      if ( dwNewCurPos.X > Info.dwSize.X )
        dwNewCurPos.X = Info.dwSize.X-1;
      if ( dwNewCurPos.X < -1 )
        dwNewCurPos.X = 0;
      dwNewCurPos.Y = y - 1;
      if ( dwNewCurPos.Y < -1 )
        dwNewCurPos.Y = 0;
      if ( dwNewCurPos.Y >= Info.dwSize.Y )
        dwNewCurPos.Y = Info.dwSize.Y-1;
      SetConsoleCursorPosition(hConOut, dwNewCurPos);
    }
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSViv(Info.dwCursorPosition.X + 1)));
    PUSHs(sv_2mortal(newSViv(Info.dwCursorPosition.Y + 1)));

# ---------------------------------------------------------
# $old_title = Title( [$new_title] );
#   Gets and sets the title bar of the current console window.
# ---------------------------------------------------------

char *
Title( ... )
  CODE:
    char * old_title;
    int len;
    New(0, old_title, MAX_TITLE_SIZE, char);
    GetConsoleTitle(old_title, MAX_TITLE_SIZE);
    if (items > 1)
      croak("Usage: Title( [new_title] )");
    else if (items ==1 )
      SetConsoleTitle( SvPV(ST(0), len) );
  RETVAL = old_title;
  OUTPUT:
    RETVAL
  CLEANUP:
    Safefree(old_title);

# ---------------------------------------------------------
# ($Xmax, $Ymax) = XYMax();
#    returns max positions of cursor.
# ---------------------------------------------------------

void
XYMax()
  PPCODE:
    CONSOLE_SCREEN_BUFFER_INFO Info;
    GetConsoleScreenBufferInfo(hConOut, &Info);
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSViv(Info.dwSize.X)));
    PUSHs(sv_2mortal(newSViv(Info.dwSize.Y)));


# ---------------------------------------------------------
#    SetConsoleSize( sx, sy )
#
# ---------------------------------------------------------

int
SetConsoleSize( sx, sy )
    int sx;
    int sy;
  CODE:
    COORD Size;
    Size.X = sx;
    Size.Y = sy;
    RETVAL = SetConsoleScreenBufferSize(hConOut, Size);
  OUTPUT:
    RETVAL

# ---------------------------------------------------------
#    ScriptCP()
#  Set the codepage of the script and return the old value.
# ---------------------------------------------------------

UINT
ScriptCP( ... )
  CODE:
    if (items > 1)
      croak("Usage: ScriptCP( [codepage] )");
    RETVAL = Cp_In;
    if (items ==1 )
      Cp_In = SvIV(ST(0));
  OUTPUT:
    RETVAL


# ---------------------------------------------------------
# $buffer = _ScreenDump();
#  Returns the part of the buffer visible on the screen.
#  This function is for tests only.
# ---------------------------------------------------------

void
_ScreenDump()
  PPCODE:
    char * buffer;
    COORD coords;
    COORD size;
    int len;
    CONSOLE_SCREEN_BUFFER_INFO Info;
    GetConsoleScreenBufferInfo(hConOut, &Info);
    size.X = Info.srWindow.Right - Info.srWindow.Left + 1;
    size.Y = Info.srWindow.Bottom - Info.srWindow.Top + 1;
    len = size.X * size.Y * sizeof(CHAR_INFO);
    New(0, buffer, len, char);
    coords.X =0;
    coords.Y=0;
    EXTEND(SP, 1);
    if (ReadConsoleOutput(
      hConOut,
      (CHAR_INFO *)buffer,
      size,
      coords,
      &Info.srWindow)
      )
      PUSHs(sv_2mortal(newSVpv(buffer, len)));
    else
      PUSHs(&PL_sv_undef);
    Safefree(buffer);

# ---------------------------------------------------------
#    _chcp()
#  Set the script and console codepages and return the old values.
#  This function is for tests only.
# ---------------------------------------------------------

void
_chcp( new_Cp_In, new_Cp_Out )
    UINT new_Cp_In;
    UINT new_Cp_Out;
  PPCODE:
    UINT old_Cp_In;
    UINT old_Cp_Out;
    old_Cp_In = Cp_In;
    Cp_In     = new_Cp_In;
    old_Cp_Out = Cp_Out;
    Cp_Out     = new_Cp_Out;
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSViv(old_Cp_In)));
    PUSHs(sv_2mortal(newSViv(old_Cp_Out)));

