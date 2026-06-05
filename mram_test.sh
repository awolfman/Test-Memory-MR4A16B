#!/bin/sh

# Переменная для хранения исходного runlevel
INITIAL_RUNLEVEL=""

cleanup_and_exit() {
    local exit_code=$1
    echo "================================================"
    echo " ОЧИСТКА И ЗАВЕРШЕНИЕ РАБОТЫ"
    echo "================================================"
    
    echo "Удаление временных файлов..."
    rm -f /tmp/tomram /tmp/frommram /tmp/diff.log
    rm -f /tmp/chunk_to /tmp/chunk_from
    
    echo "Форматирование MRAM и запуск сервисов..."
    /etc/init.d/populate-mram.sh
    sleep 1
    
    # Возвращаем систему в исходный режим, только если мы его меняли
    if [ -n "$INITIAL_RUNLEVEL" ] && [ "$INITIAL_RUNLEVEL" != "4" ]; then
        echo "Возврат системы на исходный уровень инициализации $INITIAL_RUNLEVEL..."
        init "$INITIAL_RUNLEVEL"
        sleep 1
    else
        echo "Система остается в текущем режиме (init 4 или аналогичном)."
    fi
    
    exit $exit_code
}

# ==============================================================================
#  ПОДГОТОВКА СИСТЕМЫ И ПРОВЕРКА ТЕКУЩЕГО СОСТОЯНИЯ
# ==============================================================================
echo "================================================"
# Проверка текущего runlevel
CURRENT_RUNLEVEL=$(runlevel | awk '{print $2}')

# Если утилиты runlevel нет в вашей embedded-системе, раскомментируйте строку ниже:
# CURRENT_RUNLEVEL=$(who -r | awk '{print $3}')

echo "Текущий уровень инициализации: init $CURRENT_RUNLEVEL"

if [ "$CURRENT_RUNLEVEL" = "4" ]; then
    echo "Система уже находится в режиме тестирования (init 4). Смена режима не требуется."
else
    # Запоминаем исходный runlevel для последующего возврата
    INITIAL_RUNLEVEL="$CURRENT_RUNLEVEL"
    echo "Перевод системы в режим тестирования (init 4)..."
    init 4 && sleep 1
fi

# Проверка состояния сервиса mkred
if sv s mkred 2>/dev/null | grep -q "^down:"; then
    echo "Сервис mkred уже остановлен."
else
    echo "Остановка сервиса mkred..."
    sv d mkred && sleep 1
fi

# Проверка монтирования MRAM
if ! grep -q "/mnt/mram" /proc/mounts; then
    echo "MRAM уже отмонтирована (или не была смонтирована)."
else
    echo "Размонтирование MRAM..."
    if ! umount /mnt/mram/ 2>/dev/null; then
        echo "Предупреждение: Не удалось отмонтировать /mnt/mram/, возможно устройство занято."
    fi
fi

# ==============================================================================
#  ГЕНЕРАЦИЯ И ЗАПИСЬ ДАННЫХ
# ==============================================================================
echo "================================================"
echo "Генерация случайных данных (32 МБ)..."
if ! dd if=/dev/urandom bs=4k count=8k of=/tmp/tomram 2>/dev/null; then
    echo "test failed (Ошибка создания файла в /tmp)"
    cleanup_and_exit 1
fi

echo "Запись данных в /dev/mram0..."
dd if=/tmp/tomram bs=4k count=8k of=/dev/mram0 2>/dev/null

echo "Чтение данных из /dev/mram0..."
dd if=/dev/mram0 bs=4k count=8k of=/tmp/frommram 2>/dev/null

# ==============================================================================
#  ПРОВЕРКА
# ==============================================================================
echo "================================================"
echo "Проверка контрольных сумм MD5..."
md5_to=$(md5sum /tmp/tomram | awk '{print $1}')
md5_from=$(md5sum /tmp/frommram | awk '{print $1}')

if [ "$md5_to" = "$md5_from" ] && [ -n "$md5_to" ]; then
    echo "================================================"
    echo "test successful (Все 16 микросхем MRAM исправны)"
    echo "================================================"
    cleanup_and_exit 0
else
    echo "================================================"
    echo "test failed (Обнаружено расхождение данных!)"
    echo "================================================"
    echo "Запуск глубокого анализа повреждения данных..."
    
    # Сразу сохраняем самую первую глобальную ошибку для побитового анализа в шаге 5
    cmp -l /tmp/tomram /tmp/frommram | head -n 1 > /tmp/diff.log

    # ==============================================================================
    #  БЛОЧНЫЙ АНАЛИЗ АДРЕСНОГО ПРОСТРАНСТВА ПО ЧИПАМ (8 блоков по 4 МБ)
    # ==============================================================================
    ERR_A=0
    ERR_B=0
    BAD_CHIPS=""

    # Цикл по 8 парам чипов. Каждая пара занимает 4 МБ.
    for pair_idx in 0 1 2 3 4 5 6 7; do
        # Вырезаем кусок размером 4 МБ из оригинального и считанного файлов
        # skip указывает смещение в блоках по 4 КБ (1024 блока по 4 КБ = 4 МБ)
        offset_blocks=$(( pair_idx * 1024 ))
        
        dd if=/tmp/tomram bs=4k skip=$offset_blocks count=1024 of=/tmp/chunk_to 2>/dev/null
        dd if=/dev/mram0 bs=4k skip=$offset_blocks count=1024 of=/tmp/chunk_from 2>/dev/null

        # Анализируем первые несколько ошибок внутри этого 4 МБ блока. 
        # head -n 10 гарантирует мгновенную работу, даже если блок полностью "битый".
        BLOCK_ERRORS=$(cmp -l /tmp/chunk_to /tmp/chunk_from 2>/dev/null | head -n 10)

        if [ -n "$BLOCK_ERRORS" ]; then
            # Парсим ошибки внутри конкретного блока
            echo "$BLOCK_ERRORS" | while read -r chunk_pos orig_val mram_val; do
                [ -z "$chunk_pos" ] && continue
                
                # Вычисляем индекс байта в 32-битном слове
                BYTE_INDEX=$(( (chunk_pos - 1) % 4 ))
                
                if [ $BYTE_INDEX -eq 0 ] || [ $BYTE_INDEX -eq 1 ]; then
                    # Ошибка на Стороне А
                    CHIP_ID=$(( pair_idx + 1 ))
                    echo "MARK_A|U$CHIP_ID"
                else
                    # Ошибка на Стороне B
                    CHIP_ID=$(( pair_idx + 9 ))
                    echo "MARK_B|U$CHIP_ID"
                fi
            done
        fi
    done > /tmp/block_analysis.tmp

    # Извлекаем итоговые результаты из временного файла анализа блоков
    if grep -q "MARK_A" /tmp/block_analysis.tmp; then ERR_A=1; fi
    if grep -q "MARK_B" /tmp/block_analysis.tmp; then ERR_B=1; fi

    # Собираем уникальный список неисправных чипов, убирая дубликаты через sort -u
    BAD_CHIPS=$(awk -F'|' '{print $2}' /tmp/block_analysis.tmp | sort -u | tr '\n' ' ')
    rm -f /tmp/block_analysis.tmp

    # Вывод результатов анализа работоспособности сторон (рангов)
    if [ "$ERR_A" = "1" ]; then 
        echo " -> АППАРАТНЫЙ ДЕФЕКТ: Сбой на Стороне А (чипы U1-U8, биты 0:15)"
    else
        echo " -> СТАТУС СТОРОНЫ А: Успешно (Чипы U1-U8 исправны или данные не повреждены)"
    fi

    if [ "$ERR_B" = "1" ]; then 
        echo " -> АППАРАТНЫЙ ДЕФЕКТ: Сбой на Стороне B (чипы U9-U16, биты 16:31)"
    else
        echo " -> СТАТУС СТОРОНЫ B: Успешно (Чипы U9-U16 исправны или данные не повреждены)"
    fi

    echo " -> РЕКОМЕНДАЦИЯ К ЗАМЕНЕ: Неисправны микросхемы [ $BAD_CHIPS]"
    
    # ==============================================================================
    # КРАШ-АНАЛИЗ ПЕРВОЙ ОШИБКИ И ПОБИТОВЫЙ XOR
    # ==============================================================================
    if [ -s /tmp/diff.log ]; then
        read -r first_pos oct_orig oct_mram < /tmp/diff.log
    else
        first_pos=""
    fi
    
    if [ -n "$first_pos" ]; then
        byte_shift=$(( (first_pos - 1) % 4 ))
        pair_idx=$(( (first_pos - 1) / 4194304 ))

        if [ $byte_shift -eq 0 ] || [ $byte_shift -eq 1 ]; then
            CHIP_NUM=$(( pair_idx + 1 ))
        else
            CHIP_NUM=$(( pair_idx + 9 ))
        fi
        
        dec_orig=$(( 0$oct_orig ))
        dec_mram=$(( 0$oct_mram ))
        xor_mask=$(( dec_orig ^ dec_mram ))
        bus_bit_base=$(( byte_shift * 8 ))
        hex_addr=$(printf "0x%08X" $((first_pos - 1)))
        
        echo " -> Анализ характера повреждений (по первой ошибке):"
        echo "    Адрес: $hex_addr (Смещение: $first_pos байт, Чип U$CHIP_NUM)"
        echo "    Ожидалось в байте: $dec_orig, Считано из MRAM: $dec_mram"
        echo "    Локализованные сбойные биты на общей 32-битной шине (0:31):"
        
        bit_found=0
        for bit_idx in 0 1 2 3 4 5 6 7; do
            if [ $(( (xor_mask >> bit_idx) & 1 )) -eq 1 ]; then
                global_bit=$(( bus_bit_base + bit_idx ))
                mram_bit_val=$(( (dec_mram >> bit_idx) & 1 ))
                
                if [ $mram_bit_val -eq 0 ]; then
                    echo "    [*] Линия данных D$global_bit ЗАЛИПЛА В 0 (Данные потеряны)"
                else
                    echo "    [*] Линия данных D$global_bit ЗАЛИПЛА В 1 (Данные искажены)"
                fi
                bit_found=$((bit_found + 1))
            fi
        done
        
        if [ $bit_found -eq 0 ]; then
            echo "    [!] Не удалось десериализовать битовую маску."
        fi
    fi
    
    cleanup_and_exit 1
fi
