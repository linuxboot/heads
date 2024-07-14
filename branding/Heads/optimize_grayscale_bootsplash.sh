#!/bin/bash

# Function to check if an image is effectively grayscale
is_effectively_grayscale() {
    local image="$1"
    local colors=$(identify -format "%k" "$image")
    local type=$(identify -format "%r" "$image")
    [[ "$type" == *"Gray"* ]] || [[ "$colors" -le 256 ]]
}

# Function to analyze the image
analyze_image() {
    local image="$1"
    echo "Analyzing: $image"
    
    identify -verbose "$image" | grep -E "Image:|Geometry:|Colorspace:|Type:|Depth:|Colors:|Filesize:"
    
    echo "------------------------"
}

# Function to optimize the bootsplash image
optimize_bootsplash() {
    local input_image="$1"
    local temp_image="${input_image}.temp"

    convert "$input_image" \
        -colorspace Gray \
        -define jpeg:extent=20KB \
        -quality 98 \
        -dither Riemersma \
        -strip \
        "$temp_image"

    mv "$temp_image" "$input_image"
    echo "Optimized image: $input_image"
}

# Main script
for input_image in *.jpg *.jpeg; do
    # Check if the file exists
    if [[ -f "$input_image" ]]; then
        echo "Processing: $input_image"
        analyze_image "$input_image"
        if is_effectively_grayscale "$input_image"; then
            echo "Optimizing effectively grayscale image: $input_image"
            optimize_bootsplash "$input_image"
            analyze_image "$input_image"
        else
            echo "Skipping non-grayscale image: $input_image"
        fi
    fi
done
