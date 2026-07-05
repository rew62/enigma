-- enigma-logo.lua — ENIGMA logotype with configurable inter-character spacing
-- (renamed from enigma8.lua; based on a bitmap trace of enigma.xcf)
-- v1 2026-07-04 @rew62

if not conky then require 'cairo'; pcall(require, 'cairo_xlib') end  -- conky 1.22+ splits xlib fns into cairo_xlib; no-op on older builds

local CHAR_GAP = 20   -- extra pixels of space inserted between each character
local ROTATION = 90    -- degrees CCW; 90 → portrait (logo reads upward), matches enigma.lua

local SVG_W  = 1190.2
local SVG_H  = 218.57
local LOGO_H = 16     -- rendered height of the logo before rotation

local GR, GG, GB = 0x98/255, 0xFB/255, 0x98/255   -- #98FB98 PaleGreen

local SHOW_LINES = true
local LINE_LEN   = 450    -- px; length of each decorative line
local LINE_W     = 1     -- px; stroke width
local LINE_GAP   = 20    -- px; gap between line tip and nearest char edge
local LR, LG, LB = 0xE8/255, 0xA0/255, 0x60/255  -- #E8A060 today-orange (multimon)

-- Returns 0-based character index for an SVG x coordinate.
-- Characters: E[0-200) N[200-440) I[440-490) G[490-730) M[730-995) A[995-]
local function char_index(x)
    if x < 200 then return 0
    elseif x < 440 then return 1
    elseif x < 490 then return 2
    elseif x < 730 then return 3
    elseif x < 995 then return 4
    else return 5
    end
end

local scale  = LOGO_H / SVG_H
local LOGO_W = math.ceil(SVG_W * scale + 5 * CHAR_GAP)

local CHAR_OFFSET_X = SHOW_LINES and (LINE_LEN + LINE_GAP) or 0
local COMP_W = LOGO_W + 2 * CHAR_OFFSET_X
local COMP_H = LOGO_H

local rot_rad = ROTATION * math.pi / 180
local WIN_W   = math.ceil(COMP_W * math.abs(math.cos(rot_rad)) + COMP_H * math.abs(math.sin(rot_rad)))
local WIN_H   = math.ceil(COMP_W * math.abs(math.sin(rot_rad)) + COMP_H * math.abs(math.cos(rot_rad)))

local function draw_enigma_logo8(cr)
    local function X(x) return x * scale + char_index(x) * CHAR_GAP end
    local function Y(y) return y * scale end

    cairo_set_source_rgba(cr, 0, 0, 0, 0)
    cairo_paint(cr)

    cairo_save(cr)
    cairo_translate(cr, WIN_W / 2, WIN_H / 2)
    cairo_rotate(cr, -rot_rad)
    cairo_translate(cr, -COMP_W / 2, -COMP_H / 2)

    if SHOW_LINES then
        cairo_set_source_rgb(cr, LR, LG, LB)
        cairo_set_line_width(cr, LINE_W)
        cairo_move_to(cr, 0,            COMP_H / 2)
        cairo_line_to(cr, LINE_LEN,     COMP_H / 2)
        cairo_move_to(cr, COMP_W - LINE_LEN, COMP_H / 2)
        cairo_line_to(cr, COMP_W,       COMP_H / 2)
        cairo_stroke(cr)
    end

    cairo_save(cr)
    cairo_translate(cr, CHAR_OFFSET_X, 0)
    cairo_set_source_rgb(cr, GR, GG, GB)
    cairo_move_to(cr, X(764.63), Y(199.97))
    cairo_curve_to(cr, X(768.76), Y(199.97), X(772.89), Y(199.97), X(777.32), Y(199.97))
    cairo_curve_to(cr, X(777.32), Y(206.05), X(777.32), Y(211.61), X(777.32), Y(217.54))
    cairo_curve_to(cr, X(764.88), Y(217.54), X(752.64), Y(217.54), X(740.27), Y(217.54))
    cairo_curve_to(cr, X(740.27), Y(145.48), X(740.27), Y(73.484), X(740.27), Y(0.88178))
    cairo_curve_to(cr, X(745.1), Y(0.88178), X(749.26), Y(0.56317), X(753.32), Y(1.0404))
    cairo_curve_to(cr, X(754.92), Y(1.2282), X(756.65), Y(2.9336), X(757.74), Y(4.3876))
    cairo_curve_to(cr, X(784.93), Y(40.813), X(812.05), Y(77.298), X(839.19), Y(113.76))
    cairo_curve_to(cr, X(839.48), Y(114.16), X(839.9), Y(114.46), X(840.85), Y(115.36))
    cairo_curve_to(cr, X(844.71), Y(110.41), X(848.61), Y(105.59), X(852.29), Y(100.61))
    cairo_curve_to(cr, X(876.04), Y(68.475), X(899.69), Y(36.269), X(923.55), Y(4.2239))
    cairo_curve_to(cr, X(924.87), Y(2.454), X(927.77), Y(1.3158), X(930.09), Y(0.96234))
    cairo_curve_to(cr, X(933.65), Y(0.42142), X(937.35), Y(0.82037), X(941.32), Y(0.82037))
    cairo_curve_to(cr, X(941.32), Y(73.363), X(941.32), Y(145.39), X(941.32), Y(217.87))
    cairo_curve_to(cr, X(929.07), Y(217.87), X(917.28), Y(217.94), X(905.5), Y(217.74))
    cairo_curve_to(cr, X(904.57), Y(217.73), X(902.93), Y(215.97), X(902.87), Y(214.94))
    cairo_curve_to(cr, X(902.59), Y(210.17), X(902.75), Y(205.37), X(902.75), Y(199.95))
    cairo_curve_to(cr, X(907.42), Y(199.95), X(911.66), Y(199.95), X(916.48), Y(199.95))
    cairo_curve_to(cr, X(916.48), Y(151.87), X(916.48), Y(104.42), X(916.47), Y(56.31))
    cairo_curve_to(cr, X(916.19), Y(55.734), X(915.94), Y(55.818), X(915.68), Y(55.901))
    cairo_curve_to(cr, X(895.66), Y(82.839), X(875.65), Y(109.78), X(855.63), Y(136.72))
    cairo_curve_to(cr, X(850.89), Y(143.1), X(846.15), Y(149.49), X(840.99), Y(156.45))
    cairo_curve_to(cr, X(815.73), Y(122.83), X(790.85), Y(89.696), X(765.74), Y(56.07))
    cairo_curve_to(cr, X(765.25), Y(55.687), X(764.97), Y(55.8), X(764.69), Y(55.913))
    cairo_curve_to(cr, X(764.59), Y(66.621), X(764.5), Y(77.329), X(763.94), Y(88.633))
    cairo_curve_to(cr, X(763.22), Y(90.474), X(762.72), Y(91.717), X(762.71), Y(92.962))
    cairo_curve_to(cr, X(762.67), Y(127.55), X(762.67), Y(162.15), X(762.72), Y(196.74))
    cairo_curve_to(cr, X(762.73), Y(198.12), X(763.37), Y(199.51), X(763.94), Y(200.81))
    cairo_curve_to(cr, X(764.46), Y(200.54), X(764.62), Y(200.27), X(764.66), Y(199.94))
    cairo_curve_to(cr, X(764.66), Y(199.95), X(764.63), Y(199.97), X(764.63), Y(199.97))
    cairo_close_path(cr)
    cairo_move_to(cr, X(357.64), Y(156.89))
    cairo_curve_to(cr, X(357.61), Y(153.54), X(357.57), Y(150.18), X(357.88), Y(146.11))
    cairo_curve_to(cr, X(358.04), Y(142.55), X(357.84), Y(139.72), X(357.65), Y(136.89))
    cairo_curve_to(cr, X(357.61), Y(135.51), X(357.58), Y(134.12), X(357.83), Y(132.18))
    cairo_curve_to(cr, X(357.96), Y(131.05), X(357.81), Y(130.47), X(357.66), Y(129.9))
    cairo_curve_to(cr, X(357.66), Y(105.17), X(357.66), Y(80.443), X(357.66), Y(55.716))
    cairo_curve_to(cr, X(357.17), Y(55.534), X(356.69), Y(55.351), X(356.2), Y(55.169))
    cairo_curve_to(cr, X(354.71), Y(56.543), X(353.02), Y(57.755), X(351.76), Y(59.316))
    cairo_curve_to(cr, X(323.2), Y(94.665), X(294.69), Y(130.05), X(266.18), Y(165.43))
    cairo_curve_to(cr, X(253.33), Y(181.38), X(240.39), Y(197.25), X(227.73), Y(213.33))
    cairo_curve_to(cr, X(224.84), Y(217), X(221.74), Y(218.57), X(217.15), Y(218.06))
    cairo_curve_to(cr, X(213.9), Y(217.7), X(210.57), Y(217.99), X(206.94), Y(217.99))
    cairo_curve_to(cr, X(206.94), Y(145.49), X(206.94), Y(73.608), X(206.94), Y(1.5421))
    cairo_curve_to(cr, X(215.11), Y(1.5421), X(222.99), Y(1.5421), X(231.32), Y(1.5421))
    cairo_curve_to(cr, X(231.32), Y(57.145), X(231.32), Y(112.2), X(231.32), Y(168.83))
    cairo_curve_to(cr, X(236.38), Y(162.89), X(240.56), Y(158.13), X(244.57), Y(153.23))
    cairo_curve_to(cr, X(279.78), Y(110.18), X(314.95), Y(67.106), X(350.12), Y(24.025))
    cairo_curve_to(cr, X(355.81), Y(17.059), X(361.4), Y(10.02), X(367.04), Y(3.0121))
    cairo_curve_to(cr, X(368.75), Y(0.88956), X(380.46), Y(0), X(381.72), Y(2.2132))
    cairo_curve_to(cr, X(382.61), Y(3.7823), X(382.49), Y(6.041), X(382.48), Y(7.9903))
    cairo_curve_to(cr, X(382.33), Y(40.646), X(382.05), Y(73.3), X(381.97), Y(105.96))
    cairo_curve_to(cr, X(381.88), Y(140.95), X(381.98), Y(175.95), X(382), Y(210.95))
    cairo_curve_to(cr, X(382.01), Y(213.07), X(382.01), Y(215.19), X(382.01), Y(217.66))
    cairo_curve_to(cr, X(373.61), Y(217.66), X(365.84), Y(217.66), X(358.13), Y(217.03))
    cairo_curve_to(cr, X(358.35), Y(215.61), X(358.66), Y(214.81), X(358.66), Y(214.01))
    cairo_curve_to(cr, X(358.69), Y(196.19), X(358.7), Y(178.37), X(358.64), Y(160.55))
    cairo_curve_to(cr, X(358.63), Y(159.33), X(357.99), Y(158.11), X(357.64), Y(156.89))
    cairo_move_to(cr, X(357.33), Y(53.503))
    cairo_curve_to(cr, X(357.33), Y(53.503), X(357.1), Y(53.379), X(357.1), Y(53.379))
    cairo_curve_to(cr, X(357.1), Y(53.379), X(357.15), Y(53.685), X(357.33), Y(53.503))
    cairo_close_path(cr)
    cairo_move_to(cr, X(656.96), Y(193.16))
    cairo_curve_to(cr, X(657.28), Y(176.52), X(657.28), Y(160.21), X(657.28), Y(143.35))
    cairo_curve_to(cr, X(641.44), Y(143.35), X(625.53), Y(143.35), X(609.18), Y(143.35))
    cairo_curve_to(cr, X(609.18), Y(135.45), X(609.18), Y(128.07), X(609.18), Y(120.28))
    cairo_curve_to(cr, X(633.39), Y(120.28), X(657.61), Y(120.28), X(682.07), Y(120.28))
    cairo_curve_to(cr, X(682.07), Y(152.79), X(682.07), Y(185.17), X(682.07), Y(217.82))
    cairo_curve_to(cr, X(619.94), Y(217.82), X(558.33), Y(217.82), X(496.11), Y(217.82))
    cairo_curve_to(cr, X(496.79), Y(216.49), X(497.24), Y(215.35), X(497.9), Y(214.35))
    cairo_curve_to(cr, X(512.26), Y(192.91), X(526.57), Y(171.43), X(541.03), Y(150.05))
    cairo_curve_to(cr, X(568.27), Y(109.78), X(595.61), Y(69.571), X(622.89), Y(29.32))
    cairo_curve_to(cr, X(628.4), Y(21.188), X(633.93), Y(13.063), X(639.18), Y(4.7626))
    cairo_curve_to(cr, X(640.89), Y(2.0487), X(642.68), Y(0.83954), X(645.96), Y(0.93402))
    cairo_curve_to(cr, X(654.08), Y(1.168), X(662.22), Y(1.0109), X(670.35), Y(1.0109))
    cairo_curve_to(cr, X(670.74), Y(1.4116), X(671.12), Y(1.8123), X(671.5), Y(2.2131))
    cairo_curve_to(cr, X(628.38), Y(65.607), X(585.26), Y(129), X(542.13), Y(192.4))
    cairo_curve_to(cr, X(542.4), Y(192.9), X(542.67), Y(193.4), X(542.94), Y(193.9))
    cairo_curve_to(cr, X(545.85), Y(193.9), X(548.76), Y(193.91), X(551.68), Y(193.9))
    cairo_curve_to(cr, X(586.01), Y(193.84), X(620.34), Y(193.78), X(654.67), Y(193.71))
    cairo_curve_to(cr, X(655.33), Y(193.71), X(655.99), Y(193.56), X(656.96), Y(193.16))
    cairo_close_path(cr)
    cairo_move_to(cr, X(1177.6), Y(218.16))
    cairo_curve_to(cr, X(1172.5), Y(218.14), X(1167.8), Y(217.86), X(1163.2), Y(218.19))
    cairo_curve_to(cr, X(1159.7), Y(218.44), X(1157.8), Y(216.92), X(1155.9), Y(214.22))
    cairo_curve_to(cr, X(1140.1), Y(191.62), X(1124), Y(169.11), X(1108), Y(146.63))
    cairo_curve_to(cr, X(1107.4), Y(145.75), X(1105.9), Y(144.98), X(1104.9), Y(144.98))
    cairo_curve_to(cr, X(1079.4), Y(144.89), X(1053.9), Y(144.91), X(1027.9), Y(144.91))
    cairo_curve_to(cr, X(1027.9), Y(169.23), X(1027.9), Y(193.28), X(1027.9), Y(217.64))
    cairo_curve_to(cr, X(1019.7), Y(217.64), X(1012.1), Y(217.64), X(1004.4), Y(217.64))
    cairo_curve_to(cr, X(1004.4), Y(145.5), X(1004.4), Y(73.524), X(1004.4), Y(0.7067))
    cairo_curve_to(cr, X(1014.1), Y(0.7067), X(1023.2), Y(0.63364), X(1032.3), Y(0.80859))
    cairo_curve_to(cr, X(1033.3), Y(0.82825), X(1034.5), Y(2.0696), X(1035.2), Y(3.0537))
    cairo_curve_to(cr, X(1049.1), Y(22.199), X(1062.8), Y(41.407), X(1076.6), Y(60.569))
    cairo_curve_to(cr, X(1109.4), Y(106.05), X(1142.3), Y(151.51), X(1175.1), Y(196.98))
    cairo_curve_to(cr, X(1179.9), Y(203.67), X(1184.7), Y(210.4), X(1190.2), Y(218.16))
    cairo_curve_to(cr, X(1185.3), Y(218.16), X(1181.7), Y(218.16), X(1177.6), Y(218.16))
    cairo_move_to(cr, X(1029.6), Y(36.483))
    cairo_curve_to(cr, X(1029.3), Y(36.645), X(1029.1), Y(36.808), X(1028.8), Y(37.894))
    cairo_curve_to(cr, X(1028.8), Y(65.79), X(1028.8), Y(93.686), X(1028.8), Y(121.5))
    cairo_curve_to(cr, X(1049.5), Y(121.5), X(1069.4), Y(121.5), X(1090.4), Y(121.5))
    cairo_curve_to(cr, X(1080.8), Y(108.19), X(1071.8), Y(95.659), X(1062.8), Y(83.109))
    cairo_curve_to(cr, X(1051.8), Y(67.709), X(1040.7), Y(52.297), X(1029.6), Y(36.483))
    cairo_close_path(cr)
    cairo_move_to(cr, X(52.707), Y(32.892))
    cairo_curve_to(cr, X(59.64), Y(41.579), X(66.682), Y(50.18), X(73.48), Y(58.971))
    cairo_curve_to(cr, X(84.97), Y(73.828), X(96.191), Y(88.893), X(107.79), Y(103.66))
    cairo_curve_to(cr, X(110.5), Y(107.12), X(110.85), Y(109.47), X(108.08), Y(113.11))
    cairo_curve_to(cr, X(89.048), Y(138.11), X(70.238), Y(163.28), X(51.37), Y(188.4))
    cairo_curve_to(cr, X(50.576), Y(189.46), X(49.904), Y(190.61), X(48.854), Y(192.17))
    cairo_curve_to(cr, X(48.927), Y(193.01), X(49.32), Y(193.4), X(49.713), Y(193.79))
    cairo_curve_to(cr, X(80.704), Y(193.78), X(111.7), Y(193.78), X(143.52), Y(193.81))
    cairo_curve_to(cr, X(145.49), Y(193.58), X(146.64), Y(193.31), X(147.78), Y(193.05))
    cairo_curve_to(cr, X(148.18), Y(189.26), X(148.58), Y(185.48), X(149.02), Y(181.32))
    cairo_curve_to(cr, X(154.6), Y(181.32), X(160.18), Y(181.32), X(166.25), Y(181.32))
    cairo_curve_to(cr, X(166.25), Y(192.9), X(166.25), Y(204.58), X(166.25), Y(216.59))
    cairo_curve_to(cr, X(111.27), Y(216.59), X(56.401), Y(216.59), X(0), Y(216.59))
    cairo_curve_to(cr, X(27.29), Y(180.27), X(53.944), Y(144.8), X(80.856), Y(108.98))
    cairo_curve_to(cr, X(69.588), Y(93.879), X(58.266), Y(78.71), X(47.194), Y(63.218))
    cairo_curve_to(cr, X(50.318), Y(60.745), X(53.191), Y(58.594), X(56.065), Y(56.443))
    cairo_curve_to(cr, X(55.891), Y(55.697), X(55.717), Y(54.952), X(55.543), Y(54.206))
    cairo_curve_to(cr, X(53.013), Y(53.772), X(50.388), Y(53.621), X(47.985), Y(52.812))
    cairo_curve_to(cr, X(46.09), Y(52.175), X(42.872), Y(50.515), X(42.984), Y(49.674))
    cairo_curve_to(cr, X(43.72), Y(44.128), X(42.37), Y(37.35), X(49.826), Y(34.797))
    cairo_curve_to(cr, X(50.88), Y(34.436), X(51.751), Y(33.54), X(52.707), Y(32.892))
    cairo_close_path(cr)
    cairo_move_to(cr, X(445.91), Y(136.91))
    cairo_curve_to(cr, X(445.91), Y(91.518), X(445.91), Y(46.63), X(445.91), Y(1.2569))
    cairo_curve_to(cr, X(452.3), Y(1.2569), X(457.73), Y(1.0905), X(463.15), Y(1.3308))
    cairo_curve_to(cr, X(465.66), Y(1.4421), X(469.22), Y(1.5561), X(470.34), Y(3.0971))
    cairo_curve_to(cr, X(471.62), Y(4.8599), X(470.76), Y(8.21), X(470.76), Y(10.87))
    cairo_curve_to(cr, X(470.77), Y(77.832), X(470.77), Y(144.79), X(470.77), Y(211.75))
    cairo_curve_to(cr, X(470.77), Y(213.56), X(470.77), Y(215.36), X(470.77), Y(217.61))
    cairo_curve_to(cr, X(462.42), Y(217.61), X(454.52), Y(217.61), X(445.91), Y(217.61))
    cairo_curve_to(cr, X(445.91), Y(190.9), X(445.91), Y(164.15), X(445.91), Y(136.91))
    cairo_close_path(cr)
    cairo_move_to(cr, X(52.678), Y(32.548))
    cairo_curve_to(cr, X(51.751), Y(33.54), X(50.88), Y(34.436), X(49.826), Y(34.797))
    cairo_curve_to(cr, X(42.37), Y(37.35), X(43.72), Y(44.128), X(42.984), Y(49.674))
    cairo_curve_to(cr, X(42.872), Y(50.515), X(46.09), Y(52.175), X(47.985), Y(52.812))
    cairo_curve_to(cr, X(50.388), Y(53.621), X(53.013), Y(53.772), X(55.543), Y(54.206))
    cairo_curve_to(cr, X(55.717), Y(54.952), X(55.891), Y(55.697), X(56.065), Y(56.443))
    cairo_curve_to(cr, X(53.191), Y(58.594), X(50.318), Y(60.745), X(47.082), Y(62.896))
    cairo_curve_to(cr, X(36.005), Y(48.737), X(25.285), Y(34.581), X(14.578), Y(20.416))
    cairo_curve_to(cr, X(10.212), Y(14.64), X(5.8728), Y(8.8452), X(0.62012), Y(1.8605))
    cairo_curve_to(cr, X(56.811), Y(1.8605), X(111.46), Y(1.8605), X(166.6), Y(1.8605))
    cairo_curve_to(cr, X(166.6), Y(12.081), X(166.66), Y(22.531), X(166.5), Y(32.978))
    cairo_curve_to(cr, X(166.49), Y(33.934), X(165.17), Y(35.6), X(164.32), Y(35.695))
    cairo_curve_to(cr, X(159.3), Y(36.258), X(154.23), Y(36.455), X(148.58), Y(36.813))
    cairo_curve_to(cr, X(148.58), Y(33.927), X(148.35), Y(31.453), X(148.63), Y(29.036))
    cairo_curve_to(cr, X(149.08), Y(25.083), X(147.63), Y(23.915), X(143.64), Y(23.946))
    cairo_curve_to(cr, X(119.98), Y(24.129), X(96.314), Y(24.052), X(72.652), Y(24.051))
    cairo_curve_to(cr, X(64.987), Y(24.05), X(57.322), Y(24.014), X(48.927), Y(24.009))
    cairo_curve_to(cr, X(47.984), Y(24.283), X(47.772), Y(24.542), X(47.559), Y(24.802))
    cairo_curve_to(cr, X(49.255), Y(27.269), X(50.952), Y(29.737), X(52.678), Y(32.548))
    cairo_close_path(cr)
    cairo_move_to(cr, X(763.71), Y(200.9))
    cairo_curve_to(cr, X(763.37), Y(199.51), X(762.73), Y(198.12), X(762.72), Y(196.74))
    cairo_curve_to(cr, X(762.67), Y(162.15), X(762.67), Y(127.55), X(762.71), Y(92.962))
    cairo_curve_to(cr, X(762.72), Y(91.717), X(763.22), Y(90.474), X(763.82), Y(89.088))
    cairo_curve_to(cr, X(764.29), Y(93.583), X(764.54), Y(98.219), X(764.55), Y(102.86))
    cairo_curve_to(cr, X(764.58), Y(134.91), X(764.56), Y(166.96), X(764.59), Y(199.49))
    cairo_curve_to(cr, X(764.63), Y(199.97), X(764.66), Y(199.95), X(764.42), Y(200))
    cairo_curve_to(cr, X(763.92), Y(200.28), X(763.76), Y(200.56), X(763.71), Y(200.9))
    cairo_close_path(cr)
    cairo_move_to(cr, X(357.59), Y(157.36))
    cairo_curve_to(cr, X(357.99), Y(158.11), X(358.63), Y(159.33), X(358.64), Y(160.55))
    cairo_curve_to(cr, X(358.7), Y(178.37), X(358.69), Y(196.19), X(358.66), Y(214.01))
    cairo_curve_to(cr, X(358.66), Y(214.81), X(358.35), Y(215.61), X(357.86), Y(216.69))
    cairo_curve_to(cr, X(357.53), Y(197.26), X(357.54), Y(177.54), X(357.59), Y(157.36))
    cairo_close_path(cr)
    cairo_move_to(cr, X(147.5), Y(192.84))
    cairo_curve_to(cr, X(146.64), Y(193.31), X(145.49), Y(193.58), X(143.98), Y(193.75))
    cairo_curve_to(cr, X(143.94), Y(192.83), X(144.27), Y(192.01), X(144.6), Y(191.19))
    cairo_curve_to(cr, X(145.48), Y(191.67), X(146.35), Y(192.15), X(147.5), Y(192.84))
    cairo_close_path(cr)
    cairo_move_to(cr, X(357.6), Y(137.34))
    cairo_curve_to(cr, X(357.84), Y(139.72), X(358.04), Y(142.55), X(357.94), Y(145.65))
    cairo_curve_to(cr, X(357.61), Y(143.21), X(357.58), Y(140.5), X(357.6), Y(137.34))
    cairo_close_path(cr)
    cairo_move_to(cr, X(357.61), Y(130.23))
    cairo_curve_to(cr, X(357.81), Y(130.47), X(357.96), Y(131.05), X(357.88), Y(131.77))
    cairo_curve_to(cr, X(357.62), Y(131.47), X(357.59), Y(131.02), X(357.61), Y(130.23))
    cairo_close_path(cr)
    cairo_move_to(cr, X(49.582), Y(193.41))
    cairo_curve_to(cr, X(49.32), Y(193.4), X(48.927), Y(193.01), X(48.762), Y(192.5))
    cairo_curve_to(cr, X(49.143), Y(192.6), X(49.297), Y(192.82), X(49.582), Y(193.41))
    cairo_close_path(cr)
    cairo_move_to(cr, X(764.93), Y(55.926))
    cairo_curve_to(cr, X(764.97), Y(55.8), X(765.25), Y(55.687), X(765.58), Y(55.774))
    cairo_curve_to(cr, X(765.64), Y(55.973), X(765.16), Y(55.939), X(764.93), Y(55.926))
    cairo_close_path(cr)
    cairo_move_to(cr, X(915.86), Y(55.948))
    cairo_curve_to(cr, X(915.94), Y(55.818), X(916.19), Y(55.734), X(916.43), Y(55.853))
    cairo_curve_to(cr, X(916.4), Y(56.055), X(916.04), Y(55.996), X(915.86), Y(55.948))
    cairo_close_path(cr)
    cairo_move_to(cr, X(47.798), Y(24.746))
    cairo_curve_to(cr, X(47.772), Y(24.542), X(47.984), Y(24.283), X(48.461), Y(24.017))
    cairo_curve_to(cr, X(48.57), Y(24.312), X(48.341), Y(24.539), X(47.798), Y(24.746))
    cairo_close_path(cr)
    cairo_move_to(cr, X(763.94), Y(200.81))
    cairo_curve_to(cr, X(763.76), Y(200.56), X(763.92), Y(200.28), X(764.42), Y(199.99))
    cairo_curve_to(cr, X(764.62), Y(200.27), X(764.46), Y(200.54), X(763.94), Y(200.81))
    cairo_close_path(cr)
    cairo_move_to(cr, X(357.24), Y(53.594))
    cairo_curve_to(cr, X(357.15), Y(53.685), X(357.1), Y(53.379), X(357.1), Y(53.379))
    cairo_curve_to(cr, X(357.1), Y(53.379), X(357.33), Y(53.503), X(357.24), Y(53.594))
    cairo_close_path(cr)
    cairo_move_to(cr, X(1029.6), Y(36.686))
    cairo_curve_to(cr, X(1029.7), Y(36.89), X(1029.3), Y(36.942), X(1029.1), Y(36.956))
    cairo_curve_to(cr, X(1029.1), Y(36.808), X(1029.3), Y(36.645), X(1029.6), Y(36.686))
    cairo_close_path(cr)
    cairo_fill(cr)
    cairo_restore(cr)  -- undo char translate
    cairo_restore(cr)  -- undo rotation
end

local _size_logged = false

function conky_draw_enigma_logo8()
    if conky_window == nil then return end
    if not _size_logged and conky_window.width > 0 then
        print(string.format("[%s] window: %d x %d",
            conky_config:match("([^/]+)$"), conky_window.width, conky_window.height))
        _size_logged = true
    end
    local cs = cairo_xlib_surface_create(
        conky_window.display, conky_window.drawable,
        conky_window.visual, conky_window.width, conky_window.height)
    local cr = cairo_create(cs)
    draw_enigma_logo8(cr)
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
end

if conky then
    conky.config = {
        lua_load          = './enigma-logo.lua',
        lua_draw_hook_pre = 'draw_enigma_logo8',
        background             = false,
        own_window             = true,
        own_window_type        = 'normal',
        own_window_title       = 'enigma-logo',
        own_window_hints       = 'undecorated,below,sticky,skip_taskbar,skip_pager',
        own_window_argb_visual = true,
        own_window_argb_value  = 0,
        own_window_transparent = true,
        double_buffer  = true,
        minimum_width  = WIN_W,
        minimum_height = WIN_H,
        maximum_width  = WIN_W,
        draw_shades  = false,
        draw_borders = false,
        draw_outline = false,
        update_interval = 3600,
        alignment = 'middle_right',
        gap_x = 360,
        gap_y = 0,
    }
    conky.text = [[]]
end
