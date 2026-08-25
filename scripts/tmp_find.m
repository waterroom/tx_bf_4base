rtl='C:/workbuddy_chat/tx_bf_4base/rtl';
rd=@(f) str2double(regexp(regexp(fileread(f),'\{([^}]*)\}','tokens','once'){1},'-?\d+','match'))/32768;
c1=firhalfband(16,88/300);
c2=rd(fullfile(rtl,'fdacoefs_hffir_600Mto1200M_87p5Mpass.h'));
c3=rd(fullfile(rtl,'fdacoefs_hffir_1200Mto2400M_87p5Mpass.h'));
N=8192; x=zeros(1,N); x(1)=1; y=x;
y=upsample(y,2); y=filter(c1,1,y);
y=upsample(y,2); y=filter(c2,1,y);
y=upsample(y,2); y=filter(c3,1,y);
[H,w]=freqz(y,1,65536,2.4e9); mag=20*log10(abs(H)+eps);
msk=w>=212e6; [m,i]=max(mag(msk)); ww=w(msk);
fprintf('阻带最差: %.1f dB @ %.0f MHz\n', m, ww(i)/1e6);
segs={[212 388],[388 512],[512 688],[688 812],[812 988],[988 1112],[1112 1200]};
for k=1:numel(segs)
    m2=max(mag(w>=segs{k}(1)*1e6 & w<=segs{k}(2)*1e6));
    fprintf('段 %d-%dM: %.1f dB\n', segs{k}, m2);
end
