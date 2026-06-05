# Test-Memory-MR4A16B
Проверка работоспособности микросхем памяти MR4A16B.

Testing the performance of MR4A16B memory chips
## Description
MR4A16B - 16Mb 16-bit I/O Parallel Interface MRAM.

Микросхемы MRAM расположены на плате формата SO-DIMM.
По 8 микросхем на каждой стороне. Объём модуля 32 МБ.
Сторона А: U1 - Data[15:0], Сторона Б: U9 - Data[31:16] и тд.

Тестирование проводится путём записи случайных чисел в каждую пару микросхем.
Затем выполняется чтение и сравниваются контрольные суммы по MD-5.
Определяется не исправная микросхема и выводится её номер.

The MRAM chips are located on a SO-DIMM board.
There are 8 chips on each side. The module capacity is 32 MB.
Side A: U1 - Data[15:0], Side B: U9 - Data[31:16], etc.

Testing is performed by writing random numbers to each pair of chips.
Then the chips are read and their MD-5 checksums are compared.

Testing is performed by writing random numbers to each pair of microchips.
Then the chip is read and the MD-5 checksums are compared.
The faulty microchip is identified and its number is displayed.
